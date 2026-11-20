# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #493: where a player may pass and where a regional may be parred, phase by phase.
# Rulebook S. 19 (8.1 Concession phase, 8.2 Regional/Minor phase), S. 26 (10.6 Consolidation).
describe 'G18OE pass and par rules by phase (#493)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let!(:a) { game.players[0] }
  let!(:b) { game.players[1] }

  describe 'Concession phase (8.1)' do
    def concession_round!(holders)
      holders.each_with_index do |holder, index|
        fund!(game, holder)
        give_company!(holder, game.company_by_id("CON#{index + 1}"))
      end
      game.instance_variable_set(:@concessions, game.concessions.first(holders.size))
      enter_round!(game, game.new_concession_round)
    end

    it 'offers only the par action, also to a holder with a minor and money' do
      give_company!(a, game.company_by_id('A'))
      round = concession_round!([a])

      expect(round.active_step.actions(a)).to eq(['par'])
    end

    it 'offers only the par action to a holder who cannot pay any regional' do
      round = concession_round!([a])
      a.spend(a.cash - 100, game.bank)

      expect(round.active_step.actions(a)).to eq(['par'])
    end

    it 'refuses a pass' do
      round = concession_round!([a])

      expect { act!(game, Engine::Action::Pass.new(a)) }.to raise_error(/pass/i)
      expect(round.current_entity).to eq(a)
    end

    it 'refuses to remove a regional' do
      round = concession_round!([a])
      regional = game.corporations.find { |c| game.removable_regional?(c) }
      expect(regional).not_to be_nil

      expect { act!(game, Engine::Action::Choose.new(a, choice: 'remove', target: regional)) }.to raise_error(RuntimeError)
      expect(regional.closed?).to be(false)
    end

    it 'refuses to par a regional the holder cannot pay when a regional is affordable' do
      round = concession_round!([a])
      a.spend(a.cash - 120, game.bank)
      lnwr = game.corporation_by_id('LNWR')

      expect { act!(game, Engine::Action::Par.new(a, corporation: lnwr, share_price: cell(game, 80, :par))) }
        .to raise_error(RuntimeError)
      expect(lnwr.ipoed).to be_falsey
      expect(round.current_entity).to eq(a)
    end

    it 'refuses a par-only of a holder who owns a minor' do
      give_company!(a, game.company_by_id('A'))
      concession_round!([a])
      a.spend(a.cash - 100, game.bank)
      lnwr = game.corporation_by_id('LNWR')

      expect { act!(game, Engine::Action::Par.new(a, corporation: lnwr, share_price: cell(game, 80, :par))) }
        .to raise_error(RuntimeError)
      expect(lnwr.ipoed).to be_falsey
    end
  end

  describe 'Regional/Minor stock round (8.2)' do
    let(:round) { enter_round!(game, game.stock_round) }
    let(:step) { round.active_step }
    let(:player) { round.current_entity }

    def par!(id, par = 60)
      regional = game.corporation_by_id(id)
      act!(round, Engine::Action::Par.new(player, corporation: regional, share_price: cell(game, par, :par)))
      regional
    end

    it 'floats a regional at once when it is parred, so a par never leaves a parred, unfloated regional' do
      regional = par!('LNWR')

      expect(regional.floated?).to be(true)
      expect(game.parred_regional?(regional)).to be(false)
    end

    it 'offers no par to a player who cannot pay twice the lowest par value' do
      player.spend(player.cash - 100, game.bank)
      lnwr = game.corporation_by_id('LNWR')

      expect(step.actions(player)).not_to include('par')
      expect { act!(round, Engine::Action::Par.new(player, corporation: lnwr, share_price: cell(game, 60, :par))) }
        .to raise_error(RuntimeError)
      expect(lnwr.ipoed).to be_falsey
    end

    it 'offers no par of a regional that is already parred' do
      lnwr = game.corporation_by_id('LNWR')
      game.par_corporation(lnwr, cell(game, 60, :par))
      lnwr.ipoed = true

      expect(game.can_par?(lnwr, player)).to be(false)
      expect { act!(round, Engine::Action::Par.new(player, corporation: lnwr, share_price: cell(game, 60, :par))) }
        .to raise_error(RuntimeError)
    end

    it 'lets a player pass' do
      expect(step.actions(player)).to include('pass')
    end

    it 'blocks pass while the player owns an unfloated minor' do
      give_company!(player, game.company_by_id('A'))

      expect(step.actions(player)).to include('par')
      expect(step.actions(player)).not_to include('pass')
      expect { act!(round, Engine::Action::Pass.new(player)) }.to raise_error(/pass/i)
    end

    it 'lets a player with an unfloated minor end the turn after another stock action' do
      give_company!(player, game.company_by_id('A'))
      par!('LNWR')

      expect(step.actions(player)).to include('pass')
    end

    it 'lets a player pass with a reservation still open, described as reserving a share' do
      lnwr = start_regional!(game, 'LNWR', game.players[0])
      pass_until!(round, game.players[0])
      par!('PLM')

      expect(step.entity_choices(lnwr)).to include('reserve' => 'Reserve share')
      expect(step.actions(player)).to include('pass')
      expect(step.pass_description).to eq('Pass (Reserve Share)')
    end
  end

  describe 'Consolidation phase (10.6)' do
    def consolidation!(holdings)
      allow(game).to receive(:major_phase?).and_return(true)
      game.instance_variable_set(:@turn, 2)
      holdings.each_with_index do |ids, index|
        ids.each { |id| start_regional!(game, id, game.players[index]) }
      end
      enter_round!(game, game.new_consolidation_round)
    end

    it 'blocks pass while the player presides an unconsolidated regional' do
      round = consolidation!([%w[LNWR], %w[PLM], []])

      expect(round.active_step.actions(round.current_entity)).not_to include('pass')
    end

    it 'never leaves a converted regional as an unfloated major, so 10.6 needs no pass block for one' do
      round = consolidation!([%w[LNWR], %w[PLM], []])
      major = convert!(round, game.corporation_by_id('LNWR'))

      expect(major.type).to eq(:major)
      expect(major.floated?).to be(true)
    end

    it 'lets a player with only floated majors pass' do
      round = consolidation!([[], [], []])
      player = round.current_entity
      major = start_major!(game, 'LNWR', player)
      expect(major.floated?).to be(true)
      take_treasury_shares!(game, player, major, 1)

      expect(round.active_step.actions(player)).to include('pass')
    end
  end
end
