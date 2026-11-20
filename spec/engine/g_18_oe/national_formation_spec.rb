# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE forming a national (§9.4)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:alice) { game.players[0] }
  let(:bob) { game.players[1] }
  let(:carol) { game.players[2] }
  let!(:lnwr) { start_major!(game, 'LNWR', alice) }
  let!(:plm) { start_major!(game, 'PLM', bob) }
  let(:round) { enter_round!(game, game.operating_round(1)) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::ConvertToNational) }

  def card(name)
    game.depot.upcoming.find { |t| t.name == name }
  end

  def give_train!(corporation, name)
    with_trains!(game, corporation, name).first
  end

  # Moves the game to the phase before the one the train `name` begins, without buying trains.
  def phase_before!(name)
    phase = game.class::PHASES.index { |p| p[:on] == name }
    game.phase.next! until game.class::PHASES.index { |p| p[:name] == game.phase.name } == phase - 1
    game.instance_variable_set(:@national_formation_phase, nil)
  end

  # The corporation operates and has reached its Buy Trains step.
  def operate!(corporation)
    round.instance_variable_set(:@entity_index, round.entities.index(corporation))
    round.instance_variable_set(:@current_operator, corporation)
    round.steps.each do |s|
      break if s.is_a?(Engine::Game::G18OE::Step::BuyTrain)

      s.pass! unless s.is_a?(Engine::Game::G18OE::Step::ConvertToNational)
    end
  end

  # The purchase as Step::BuyTrain makes it: the train changes owner, then the phase moves on.
  def buy_first!(corporation, name)
    phase_before!(name)
    train = card(name)
    operate!(corporation)
    fund!(game, corporation, train.price)
    game.buy_train(corporation, train, train.price)
    game.phase.buying_train!(corporation, train, game.depot)
    train
  end

  def convert!(corporation)
    act!(round, Engine::Action::Convert.new(corporation))
  end

  def pass!(player)
    act!(round, Engine::Action::Pass.new(player))
  end

  describe 'the trigger' do
    it 'opens the formation when the first level 4 train is bought (Train Phase 4)' do
      buy_first!(plm, '4')

      expect(round.active_step).to eq(step)
      expect(game.national_formation[:phase]).to eq('4')
    end

    it 'starts with the player whose railroad bought the train, then follows player order' do
      start_major!(game, 'GWR', carol)
      buy_first!(plm, '4')

      expect(step.current_entity).to eq(bob)
      pass!(bob)
      expect(step.current_entity).to eq(carol)
      pass!(carol)
      expect(step.current_entity).to eq(alice)
      pass!(alice)
      expect(round.active_step).not_to eq(step)
      expect(game.national_formation).to be_nil
    end

    it 'skips players without a major' do
      buy_first!(plm, '4')
      pass!(bob)

      expect(step.current_entity).to eq(alice)
    end

    { '6' => '6', '8' => '8+8' }.each do |phase, train|
      it "opens the formation again at Train Phase #{phase}" do
        game.instance_variable_set(:@level_8_available, true)
        buy_first!(lnwr, train)

        expect(game.national_formation[:phase]).to eq(phase)
        expect(step.current_entity).to eq(alice)
      end
    end

    { '3' => '3', '5' => '5', '7' => '7+7' }.each do |phase, train|
      it "does not open it at Train Phase #{phase}" do
        buy_first!(lnwr, train)

        expect(game.national_formation).to be_nil
        expect(step.active?).to be(false)
      end
    end

    it 'does not open it when no player has a major' do
      game2 = new_game
      minor = start_minor!(game2, 'K', game2.players.first, 'RU')
      game2.phase.next!
      train = game2.depot.upcoming.find { |t| t.name == '4' }
      game2.buy_train(minor, train, :free)
      game2.phase.buying_train!(minor, train, game2.depot)

      expect(game2.national_formation).to be_nil
    end
  end

  describe 'the choice' do
    it 'offers each major of the player and a pass' do
      gwr = start_major!(game, 'GWR', alice)
      buy_first!(lnwr, '4')

      expect(step.actions(alice)).to eq(['pass'])
      expect(step.actions(lnwr)).to eq(['convert'])
      expect(step.actions(gwr)).to eq(['convert'])
      expect(step.actions(plm)).to eq([])
    end

    it 'lets a player convert several majors, then moves on' do
      gwr = start_major!(game, 'GWR', alice)
      buy_first!(lnwr, '4')
      convert!(lnwr)
      expect(step.current_entity).to eq(alice)
      convert!(gwr)

      expect([lnwr.type, gwr.type]).to eq(%i[national national])
      expect(step.current_entity).to eq(bob)
    end

    it 'refuses another player converting a major that is not theirs' do
      buy_first!(lnwr, '4')

      expect { step.process_convert(Engine::Action::Convert.new(plm)) }.to raise_error(Engine::GameError)
    end

    it 'gives the turn back to the railroad that bought the train' do
      buy_first!(lnwr, '4')
      pass!(alice)
      pass!(bob)

      expect(round.active_step).not_to be_a(Engine::Game::G18OE::Step::ConvertToNational)
      expect(round.current_entity).to eq(lnwr)
    end
  end

  describe 'the steps of the formation' do
    let(:city) { game.hex_by_id(lnwr.coordinates).tile.cities.first }

    before do
      give_train!(lnwr, '2+2')
      give_train!(lnwr, '3')
      fund!(game, lnwr, 500)
      buy_first!(plm, '4')
      pass!(bob)
    end

    it 'puts all its cash into the bank (step 1)' do
      cash = lnwr.cash
      expect { convert!(lnwr) }.to change { game.bank.cash }.by(cash)
      expect(lnwr.cash).to eq(0)
    end

    it 'puts its treasury shares into the Open Market without moving the price (step 1)' do
      treasury = lnwr.treasury_shares.reject(&:president).map(&:percent).sum
      price = lnwr.share_price
      convert!(lnwr)

      expect(lnwr.treasury_shares).to be_empty
      expect(game.share_pool.percent_of(lnwr)).to eq(treasury)
      expect(treasury).to be > 50
      expect(lnwr.share_price).to eq(price)
    end

    it 'keeps the shares in the players hands' do
      percent = alice.percent_of(lnwr)
      convert!(lnwr)

      expect(alice.percent_of(lnwr)).to eq(percent)
      expect(lnwr.owner).to eq(alice)
    end

    it 'removes all its tokens from the map and from play (step 2, §11.2.2)' do
      expect(city.tokened_by?(lnwr)).to be(true)
      convert!(lnwr)

      expect(city.tokened_by?(lnwr)).to be(false)
      expect(lnwr.tokens).to be_empty
    end

    it 'loses its Orient Express marker (step 4)' do
      game.place_orient_express_marker!(lnwr)
      convert!(lnwr)

      expect(game.orient_express_marker?(lnwr)).to be(false)
    end

    it 'loses the pass-through token of a private from the map (step 4, §14.5/§14.6)' do
      port = game.hexes.flat_map { |hex| hex.tile.cities }.find { |c| game.port_accesses(c).any? && c.tokens.compact.empty? }
      game.place_pass_token!(game.company_by_id('SHTC'), port, lnwr)
      expect(game.pass_token_city?(port, lnwr)).to be(true)
      convert!(lnwr)

      expect(game.pass_token_city?(port, lnwr)).to be(false)
      expect(port.extra_tokens).to be_empty
    end

    describe 'the Swift Metropolitan Line marker (step 4, §14.10)' do
      let(:sml) { give_company!(alice, game.company_by_id('SML')) }
      let!(:sml_train) { game.sml_pool.first }

      # the rusted 2+2 cards left unclaimed at Train Phase 4 are the pool of the private (§11.6.6)
      before { game.sml_assign!(sml, lnwr) }

      it 'is removed, the 2+2 stays and now counts against the train limit; the certificate stays' do
        expect(game.num_corp_trains(lnwr)).to eq(lnwr.trains.size - 1)
        convert!(lnwr)

        expect(game.sml_train).to be_nil
        expect(lnwr.trains).to include(sml_train)
        expect(game.num_corp_trains(lnwr)).to eq(lnwr.trains.size)
        expect(sml.owner).to eq(alice)
        expect(game.face_down_private?(sml)).to be(true)
      end
    end

    it 'keeps its trains, including the 2+2 that rusted at this phase change' do
      convert!(lnwr)

      expect(lnwr.trains.map(&:name).sort).to eq(%w[2+2 3])
      expect(lnwr.trains.find { |t| t.name == '2+2' }.rusted).to be(true)
    end

    it 'flips the charter to a national' do
      convert!(lnwr)

      expect(lnwr.type).to eq(:national)
      expect(game.train_limit(lnwr)).to eq(4)
    end

    it 'leaves the rusted trains gone for a major that stays a major' do
      pass!(alice)

      expect(lnwr.trains.map(&:name)).to eq(['3'])
    end
  end

  # §9.4 step 3 and §9.5: the minors merged with the forming national are abandoned.
  describe 'the merged minors (step 3, §9.5)' do
    let(:minor) { start_minor!(game, 'B', alice, 'SP') }
    let(:minor_d) { start_minor!(game, 'D', alice, 'UK') }
    let(:nancy) { game.hex_by_id('Q38') }

    # The state Step::MergeMinor and Step::MergeToken leave: trains and abilities with the major,
    # the charter merged and closed (§10.5).
    def merge!(merging, major)
      game.transfer(:trains, merging, major)
      merging.presidents_share.counts_for_limit = false
      game.add_minor_charter!(merging, major)
      game.minor_regional_order.delete(merging)
      game.close_corporation(merging, quiet: true)
    end

    before do
      give_train!(minor, '2+2')
      merge!(minor, lnwr)
    end

    context 'when the major converts' do
      before do
        buy_first!(plm, '4')
        pass!(bob)
      end

      it 'puts the charter into the Open Market as an abandoned minor (step 1)' do
        convert!(lnwr)

        expect(minor).not_to be_closed
        expect(game.corporations).to include(minor)
        expect(game.abandoned_minors).to eq([minor])
        expect(minor.owner).to be_nil
        expect(alice.percent_of(minor)).to eq(0)
        expect(game.operating_order).not_to include(minor)
      end

      it 'leaves the trains with the national (step 2: a subsidiary of a converting major)' do
        convert!(lnwr)

        expect(minor.trains).to be_empty
        expect(lnwr.trains.map(&:name)).to eq(['2+2'])
      end

      it 'keeps the track rights chit with the minor charter, not the national (step 5)' do
        expect(game.track_rights_zones(lnwr)).to include('SP')
        convert!(lnwr)

        expect(game.minor_floated_regions[minor.id]).to eq('SP')
        expect(game.track_rights_zones(lnwr)).not_to include('SP')
        expect(game.merged_minors[lnwr]).to be_empty
      end

      it 'moves the minor ability back to its charter (workshop #203-205)' do
        ability = lnwr.abilities.first
        expect(ability).not_to be_nil
        convert!(lnwr)

        expect(lnwr.abilities).to be_empty
        expect(minor.abilities).to eq([ability])
      end

      it 'lets another major buy the abandoned minor in its Buy or Sell Shares step (§11.7)' do
        convert!(lnwr)
        gwr = start_major!(game, 'GWR', carol)
        fund!(game, gwr, 500)
        round.instance_variable_set(:@current_operator, gwr)

        expect(round_step(round, Engine::Game::G18OE::Step::IssueShares).choice_corporations(gwr)).to eq([minor])
      end
    end

    it 'puts the D minor token back with its charter (step 4)' do
      merge!(minor_d, lnwr)
      game.green_junction_place!(lnwr, nancy)
      buy_first!(plm, '4')
      pass!(bob)
      convert!(lnwr)

      expect(game.green_junction_hex).to be_nil
      expect(nancy.assigned?('D')).to be(false)
      expect(game.green_junction_holder?(lnwr)).to be(false)
      expect(game.green_junction_holder?(minor_d)).to be(true)
      expect(game.abandoned_minors).to contain_exactly(minor, minor_d)
    end

    it 'leaves the minors of a major that stays a major alone' do
      buy_first!(plm, '4')
      pass!(bob)
      pass!(alice)

      expect(minor).to be_closed
      expect(game.merged_minors[lnwr]).to eq([minor])
    end
  end

  it 'lets a national keep the trains that rust at a later phase' do
    give_train!(lnwr, '3')
    buy_first!(plm, '4')
    pass!(bob)
    convert!(lnwr)
    buy_first!(plm, '6')

    # §11.6.6 (#64): a national's rusted train is turned to its local side for free.
    expect(lnwr.trains.map(&:name)).to eq(['3+3'])
    expect(lnwr.trains.first.rusted).to be(true)
  end

  describe 'the train limit' do
    before do
      game.phase.next!
      %w[2+2 2+2 3 3].each { |name| give_train!(lnwr, name) }
      buy_first!(lnwr, '4')
      convert!(lnwr)
      pass!(bob)
    end

    it 'makes a national over its limit discard, a rusted train leaving play' do
      expect(lnwr.trains.size).to eq(5)
      expect(round.active_step).to be_a(Engine::Game::G18OE::Step::DiscardTrain)
      rusted = lnwr.trains.find(&:rusted)
      act!(round, Engine::Action::DiscardTrain.new(lnwr, train: rusted))

      expect(lnwr.trains.size).to eq(4)
      expect(rusted.owner).to be_nil
      expect(game.depot.discarded).not_to include(rusted)
    end
  end

  describe 'Lille (§11.2.2)' do
    let(:lille) { game.hex_by_id('N31').tile.cities.first }

    before do
      game.remove_wcf_placeholder!
      lille.place_token(lnwr, lnwr.next_token, free: true, check_tokenable: false, extra_slot: true)
      buy_first!(plm, '4')
      pass!(bob)
    end

    it 'is open for good once the national removes the White Cliffs Ferry token' do
      convert!(lnwr)

      expect(lille.extra_tokens.map(&:type)).to eq([:neutral])
      expect(game.wcf_placeholder).not_to be_nil
    end
  end
end
