# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'
require 'oe/bot'
require 'json'

# §15.11 Minor L (Krasnaya Strela): its marker, assigned to one train at the beginning of the RR's run trains
# step (reassignable each OR), adds one to the train's city limit and to the towns it may count: a 2+2 runs
# as a 3+3, an 8+8 as a 9+9, a 4 as a 5+1. On a D train the extra city does not double. §12.1: it may be
# used on a train combined for the Orient Express.
#
# Map: Lille (N31) between two cities O30 and O32 (the network of multiple_trains_spec): O30 - Lille - O32
# has three cities, one more than a 2+2 may count.
describe 'G18OE Minor L, Krasnaya Strela (§15.11)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let(:minor) { start_minor!(game, 'L', player, 'FR') }
  let(:lille) { game.hex_by_id('N31').tile.cities.first }
  let(:west) { game.hex_by_id('O30').tile.cities.first }
  let(:east) { game.hex_by_id('O32').tile.cities.first }

  def lay!(hex_id, name, rotation)
    tile = game.tiles.find { |t| t.name == name && !t.hex }
    tile.rotate!(rotation)
    game.hex_by_id(hex_id).lay(tile)
  end

  def train!(name, entity = minor)
    train = game.depot.upcoming.find { |t| t.name == name }
    game.buy_train(entity, train, :free)
    train
  end

  # Puts `entity` first in the OR and walks to its Route step.
  def route_round!(entity = minor)
    game.minor_regional_order.delete(entity)
    game.minor_regional_order.unshift(entity)
    round = enter_round!(game, game.operating_round(1))
    round.setup
    5.times do
      break if round.active_step.is_a?(Engine::Game::G18OE::Step::Route)

      act!(game, Engine::Action::Pass.new(round.current_entity))
    end
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::Route)
    round
  end

  def assigns(entity = minor)
    Oe::LegalActions.new(game).call.select { |a| a.is_a?(Engine::Action::Assign) && a.entity == entity }
  end

  def rows(train)
    train.distance.map { |row| [row['nodes'], row['pay'], row['visit'], row['multiplier']] }
  end

  before do
    minor
    lay!('N31', 'OE33', 0)
    lay!('O30', '57', 0)
    lay!('O32', '57', 2)
    west.place_token(minor, minor.next_token, free: true, check_tokenable: false)
    game.graph.clear
  end

  describe 'the +1+1 rows (§15.11 examples)' do
    {
      '2+2' => [2, 2, 3, 3],
      '8+8' => [8, 8, 9, 9],
      '4' => [4, 0, 5, 1],
    }.each do |name, (cities, towns, new_cities, new_towns)|
      it "runs a #{name} as a #{new_cities}+#{new_towns}" do
        train = game.depot.trains.find { |t| t.variants.key?(name) }
        train.variant = name
        expect(game.distance(train)).to eq([cities, towns])

        expect(game.krasnaya_rows(train).map { |r| r['pay'] }.reverse).to eq([new_cities, new_towns])
        expect(game.krasnaya_rows(train).find { |r| r['nodes'] != ['town'] }['visit']).to eq(new_cities)
      end
    end

    it 'counts the extra town of a D train at its single value' do
      train = game.depot.trains.find { |t| t.variants.key?('4D') }
      train.variant = '4D'
      town_row = game.krasnaya_rows(train).find { |r| r['nodes'] == ['town'] }

      expect(town_row['pay']).to eq(1)
      expect(town_row['multiplier']).to eq(1)
    end
  end

  describe 'assignment in the run trains step' do
    let!(:two) { train!('2+2') }

    it 'offers the marker on each train that has not run, and assigns it (JSON round trip)' do
      round = route_round!
      expect(round.active_step.actions(minor)).to include('assign')
      action = assigns.find { |a| a.target == two }
      expect(action).not_to be_nil

      action = Engine::Action::Base.action_from_h(JSON.parse(JSON.generate(action.to_h)), game)
      act!(game, action)

      expect(game.krasnaya_train).to eq(two)
      expect(game.distance(two)).to eq([3, 3])
      expect(game.log.map(&:message)).to include('L assigns the Krasnaya Strela marker (+1+1) to its 2+2 train')
      expect(assigns).to be_empty
    end

    it 'lets the 2+2 count a third city: O30 - Lille - O32' do
      route_round!
      route = lambda do
        Engine::Route.new(game, game.phase, two, routes: []).tap do |r|
          r.routes = [r]
          [west, lille, east].each { |node| r.touch_node(node) }
        end
      end
      expect { route.call.revenue }.to raise_error(Engine::GameError)

      act!(game, Engine::Action::Assign.new(minor, target: two))
      three = route.call
      expect(three.visited_stops).to include(west, lille, east)
      expect(three.revenue).to eq([west, lille, east].sum { |c| c.route_revenue(game.phase, two) })
    end

    it 'gives the train its own rows back at the end of the operating turn' do
      route_round!
      act!(game, Engine::Action::Assign.new(minor, target: two))
      act!(game, Engine::Action::RunRoutes.new(minor, routes: []))
      expect(game.distance(two)).to eq([3, 3])
      act!(game, Engine::Action::Pass.new(minor)) # buy trains: the turn ends

      expect(game.krasnaya_train).to be_nil
      expect(game.distance(two)).to eq([2, 2])
    end

    it 'is offered again in the next OR, also for another train' do
      other = train!('2+2')
      route_round!
      act!(game, Engine::Action::Assign.new(minor, target: two))
      game.krasnaya_release!

      expect(game.krasnaya_trains(minor)).to contain_exactly(two, other)
    end

    it 'is not offered to another RR' do
      regional = start_regional!(game, 'LNWR', player)
      train!('2+2', regional)

      expect(game.krasnaya_trains(regional)).to be_empty
    end

    it 'is assigned by a bot before it runs its routes' do
      route_round!
      action = Oe::Bot.new(game, rng: Random.new(1)).choose(player_id: player.id)

      expect(action).to be_a(Engine::Action::Assign)
      expect(action.target).to eq(two)
    end
  end

  it 'goes on the train with the most city places when a bot chooses' do
    train!('2+2')
    three = train!('3')
    route_round!
    action = Oe::Bot.new(game, rng: Random.new(1)).choose(player_id: player.id)

    expect(action.target).to eq(three)
  end

  describe 'a D train (§15.11: the extra city does not double)' do
    it 'leaves the cheapest city of the extended route single' do
      train = game.depot.trains.find { |t| t.variants.key?('4D') }
      train.variant = '4D'
      game.buy_train(minor, train, :free)
      route_round!
      act!(game, Engine::Action::Assign.new(minor, target: train))

      cities = [50, 40, 30, 20, 10].map do |value|
        double("city #{value}", town?: false, route_base_revenue: value, route_revenue: 2 * value)
      end
      route = double('route', train: train, phase: game.phase)

      expect(game.krasnaya_revenue_change(route, cities)).to eq(-10)
      expect(game.krasnaya_revenue_change(route, cities.first(4))).to eq(0)
    end

    it 'changes nothing for a train without the marker' do
      train = game.depot.trains.find { |t| t.variants.key?('4D') }
      train.variant = '4D'
      cities = [50, 40, 30, 20, 10].map { |v| double('city', town?: false, route_base_revenue: v) }

      expect(game.krasnaya_revenue_change(double('route', train: train, phase: game.phase), cities)).to eq(0)
    end
  end

  describe 'on a train combined for the Orient Express (§12.1)' do
    let(:major) { start_major!(game, 'LNWR', player) }

    before do
      allow(game).to receive(:orient_express_reachable?).and_return(true)
      train!('2+2', major)
      train!('2+2', major)
      game.add_minor_charter!(minor, major)
    end

    it 'adds +1+1 to the combined train when it is on a component' do
      route_round!(major)
      component = major.trains.first
      act!(game, Engine::Action::Assign.new(major, target: component))
      act!(game, Engine::Action::DoubleHeadTrains.new(major, trains: major.trains.dup))

      combined = major.trains.find { |t| game.combined_train?(t) }
      expect(game.distance(combined)).to eq([5, 5])
      expect(combined.name).to eq('5+5')
    end

    it 'may go on the combined train itself' do
      route_round!(major)
      act!(game, Engine::Action::DoubleHeadTrains.new(major, trains: major.trains.dup))
      combined = major.trains.find { |t| game.combined_train?(t) }
      act!(game, Engine::Action::Assign.new(major, target: combined))

      expect(game.distance(combined)).to eq([5, 5])
    end
  end

  it 'moves to the major with the charter on a merge (§10.5)' do
    major = start_major!(game, 'LNWR', player)
    game.add_minor_charter!(minor, major)

    expect(game.krasnaya_holder?(major)).to be(true)
    expect(game.krasnaya_holder?(minor)).to be(false)
  end
end
