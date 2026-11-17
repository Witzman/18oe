# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# §11.3.10 Calculating National Revenue; playbook 4.6 (SFR runs for £1,410).
describe 'G18OE national revenue (§11.3.10)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:alice) { game.players[0] }

  def card(name)
    game.depot.upcoming.find { |t| t.name == name } || game.depot.upcoming.find { |t| t.variants.key?(name) }
  end

  # A train of `name` (a variant name such as '4+4' or '4D' flips the card) owned by `corporation`.
  def give!(corporation, name, rusted: false)
    train = card(name)
    train.variant = name
    game.buy_train(corporation, train, :free)
    train.rusted = rusted
    train
  end

  describe 'counting (steps 2 to 4 and the Pullman)' do
    it 'gives the playbook 4.6 run of the SFR: two 4+4 and a 5D for £1,410' do
      capacity = Engine::Game::G18OE::National::Capacity.new(5, 8, 8)
      run = game.count_national_revenue(
        capacity,
        linked_cities: [100, 80, 80, 80, 80, 60, 60, 40, 30],
        unlinked_cities: 1, # Cagliari: no track, counts zero
        linked_towns: [20, 20, 20, 20, 10, 10, 10, 10],
        unlinked_towns: 0,
        pullman_level: 8,
      )

      expect(run.doubled).to eq([100, 80, 80, 80, 80])
      expect(run.cities).to eq([60, 60, 40, 30])
      expect(run.zero_cities).to eq(1)
      expect(run.filled_cities).to eq(3)
      expect(run.pullman).to eq(80)
      expect(run.revenue).to eq(1410)
    end

    it 'counts the most valuable linked places first and doubles the best of them for the D trains' do
      capacity = Engine::Game::G18OE::National::Capacity.new(1, 1, 1)
      run = game.count_national_revenue(capacity, linked_cities: [30, 50, 40], unlinked_cities: 0,
                                                  linked_towns: [10, 20], unlinked_towns: 0, pullman_level: 0)

      expect(run.doubled).to eq([50])
      expect(run.cities).to eq([40])
      expect(run.towns).to eq([20])
      expect(run.revenue).to eq(100 + 40 + 20)
    end

    it 'lets unlinked places take the capacity linked places leave at £0, then fills it at £60 and £10' do
      capacity = Engine::Game::G18OE::National::Capacity.new(0, 4, 3)
      run = game.count_national_revenue(capacity, linked_cities: [30], unlinked_cities: 2,
                                                  linked_towns: [], unlinked_towns: 1, pullman_level: 0)

      expect(run.zero_cities).to eq(2)
      expect(run.filled_cities).to eq(1)
      expect(run.zero_towns).to eq(1)
      expect(run.filled_towns).to eq(2)
      expect(run.revenue).to eq(30 + 60 + 20)
    end

    it 'does not let unlinked places cost anything once the linked ones fill the capacity' do
      capacity = Engine::Game::G18OE::National::Capacity.new(0, 2, 1)
      run = game.count_national_revenue(capacity, linked_cities: [30, 20, 10], unlinked_cities: 5,
                                                  linked_towns: [10, 10], unlinked_towns: 5, pullman_level: 0)

      expect(run.cities).to eq([30, 20])
      expect([run.zero_cities, run.filled_cities, run.zero_towns, run.filled_towns]).to eq([0, 0, 0, 0])
      expect(run.revenue).to eq(60)
    end

    it 'fills spare D capacity at the flat £60 (ASSUMPTION: step 4 names no doubling)' do
      capacity = Engine::Game::G18OE::National::Capacity.new(2, 0, 0)
      run = game.count_national_revenue(capacity, linked_cities: [40], unlinked_cities: 0,
                                                  linked_towns: [], unlinked_towns: 0, pullman_level: 0)

      expect(run.revenue).to eq(80 + 60)
    end
  end

  describe 'capacity (step 1)' do
    let(:sfr) { start_major!(game, 'SFR', alice) }

    it 'adds the cities, towns and double cities of all trains (rulebook: 4+4, 5 and 4D)' do
      give!(sfr, '4+4')
      give!(sfr, '5')
      give!(sfr, '4D')

      capacity = game.national_capacity(sfr)
      expect([capacity.doubled, capacity.cities, capacity.towns]).to eq([4, 9, 4])
      expect(capacity.doubled + capacity.cities).to eq(13)
    end

    it 'counts rusted trains (a national runs them, §9.4, §11.6.6)' do
      give!(sfr, '2+2', rusted: true)
      give!(sfr, '3+3', rusted: true)

      capacity = game.national_capacity(sfr)
      expect([capacity.doubled, capacity.cities, capacity.towns]).to eq([0, 5, 5])
    end
  end

  describe 'the inherent Pullman (§11.3.10, £10 per level, §11.3.9)' do
    let(:sfr) { start_major!(game, 'SFR', alice) }

    it 'rides the highest level train' do
      give!(sfr, '3+3')
      give!(sfr, '5')
      expect(game.national_pullman_level(sfr)).to eq(5)
    end

    it 'counts a 4D as level 7 and a 5D as level 8 (§11.3.2)' do
      give!(sfr, '4D')
      expect(game.national_pullman_level(sfr)).to eq(7)
      give!(sfr, '5D')
      expect(game.national_pullman_level(sfr)).to eq(8)
    end

    it 'is nothing without a train' do
      expect(game.national_pullman_level(sfr)).to eq(0)
    end
  end

  describe 'on the map' do
    let(:bob) { game.players[1] }
    let(:sfr) { start_major!(game, 'SFR', alice).tap { |c| game.form_national!(c) } }
    let(:lnwr) { start_major!(game, 'LNWR', alice).tap { |c| game.form_national!(c) } }

    def stop_at(hex_id, kind = :cities)
      game.hex_by_id(hex_id).tile.send(kind).first
    end

    it 'counts a city without track at £0, as Cagliari in playbook 4.6' do
      expect(game.national_linked?(stop_at('AC40'), sfr)).to be(false)
    end

    it 'links a red zone only the sea reaches through a zone city with track to a port on its sea zone (Tunis, Napoli)' do
      tunis = stop_at('AG40', :offboards)
      expect(game.national_track_linked?(tunis, sfr)).to be(false)
      expect(game.national_linked?(tunis, sfr)).to be(true)
    end

    it 'links the cities that track joins to another place (London, Liverpool, Manchester)' do
      %w[M28 J25 J27].each { |hex| expect(game.national_linked?(stop_at(hex), lnwr)).to be(true) }
      expect(game.national_linked?(stop_at('F25'), lnwr)).to be(false) # Glasgow: no track yet
    end

    it 'holds a virtual token: a city full of other tokens still counts (§11.3.10)' do
      gwr = start_major!(game, 'GWR', bob)
      london = stop_at('M28')
      london.place_token(gwr, gwr.next_token, check_tokenable: false)

      expect(london.tokens.compact).not_to be_empty
      expect(game.national_linked?(london, lnwr)).to be(true)
    end

    it 'does not link over track marked by a Brandt & Brandau token of another player (§14.9)' do
      bbe = give_company!(bob, game.company_by_id('BBE'))
      london = stop_at('M28')
      game.bbe_place_token!(london.hex, bbe)

      expect(game.national_linked?(london, lnwr)).to be(false)
    end

    it 'runs the SFR with a 4+4 at the start: Tunis £30, three unlinked cities, four linked towns at £0, Pullman £40' do
      give!(sfr, '4+4')
      run = game.national_run(sfr)

      expect([run.doubled, run.cities, run.zero_cities, run.filled_cities]).to eq([[], [30], 3, 0])
      expect([run.towns.size, run.zero_towns, run.filled_towns]).to eq([4, 0, 0])
      expect(game.national_revenue(sfr)).to eq(30 + 40)
    end

    it 'earns nothing without a train' do
      expect(game.national_revenue(sfr)).to eq(0)
    end
  end

  describe 'in the operating round (§11.3.10, §11.4)' do
    let(:sfr) { start_major!(game, 'SFR', alice).tap { |c| game.form_national!(c) } }
    let(:round) { operating_round_for!(game) }

    def at_step(klass)
      round.instance_variable_set(:@entity_index, round.entities.index(sfr))
      round.instance_variable_set(:@current_operator, sfr)
      round_step(round, klass)
    end

    before { give!(sfr, '4+4') }

    it 'runs no routes' do
      expect(at_step(Engine::Game::G18OE::Step::Route).actions(sfr)).to eq([])
    end

    it 'pays all its revenue out by itself and logs how it counted' do
      step = at_step(Engine::Game::G18OE::Step::Dividend)
      expect(step.actions(sfr)).to eq([])
      cash = alice.cash
      percent = alice.percent_of(sfr)

      step.skip!

      expect(sfr.operating_history[[game.turn, 1]].revenue).to eq(70)
      expect(sfr.operating_history[[game.turn, 1]].dividend.kind).to eq('payout')
      expect(alice.cash - cash).to eq((70 * percent / 100.0).ceil)
      expect(sfr.cash).to eq(0)
      expect(game.log.map(&:message).join("\n")).to include('SFR runs its national service for £70')
    end
  end
end
