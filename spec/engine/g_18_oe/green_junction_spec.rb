# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'
require 'oe/bot'
require 'json'

# §15.4 Minor D (Green Junction Mercantile): its token in any city except a metropolis or red zone
# (reachable or not) adds £20 to the trains of the minor (or the major it merged into) run to or
# through that city in Train Phase 2-4; at the start of Phase 5 it is removed and a £40 token may
# be placed. Placed in the RR's lay track step, may be delayed. §11.3.9: "D" trains double it.
# §9.5: on abandoning the minor the token goes back to the charter.
describe 'G18OE Minor D, Green Junction Mercantile (§15.4)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let(:minor) { start_minor!(game, 'D', player, 'SP') }
  let(:nancy) { game.hex_by_id('Q38') }

  def operating!
    minor
    enter_round!(game, game.operating_round(1))
  end

  def placements(entity = minor)
    Oe::LegalActions.new(game).call.select { |a| a.is_a?(Engine::Action::Assign) && a.entity == entity }
  end

  def stop(hex, city: true)
    Struct.new(:hex, :city) { def city? = city }.new(hex, city)
  end

  def route(owner, hexes, multiplier: nil)
    train = Struct.new(:owner, :multiplier).new(owner, multiplier)
    Struct.new(:train, :visited_stops).new(train, hexes.map { |hex| stop(hex) })
  end

  it 'takes any city except a metropolis or a red zone' do
    ids = game.green_junction_hexes.map(&:id)

    expect(ids).to include('Q38', 'W64', 'G26')
    expect(ids).not_to include('Q30', 'M28', 'A56', 'R51')
  end

  it 'offers the token to Minor D in its lay track step, also for a city it cannot reach, and places it' do
    round = operating!
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::Track)
    action = placements.find { |a| a.target == nancy }
    expect(action).not_to be_nil

    action = Engine::Action::Base.action_from_h(JSON.parse(JSON.generate(action.to_h)), game)
    act!(round, action)

    expect(game.green_junction_hex).to eq(nancy)
    expect(nancy.assigned?('D')).to be(true)
    expect(placements).to be_empty
  end

  it 'is placed by a bot as soon as it may' do
    round = operating!
    action = Oe::Bot.new(game, rng: Random.new(1)).choose(player_id: player.id)

    expect(action).to be_a(Engine::Action::Assign)
    expect(game.green_junction_hexes).to include(action.target)
    act!(round, action)
    expect(game.green_junction_hex).to eq(action.target)
  end

  it 'may be delayed: passing the step leaves the token with the charter' do
    round = operating!
    act!(round, Engine::Action::Pass.new(minor))

    expect(game.green_junction_hex).to be_nil
    expect(game.green_junction_placeable?(minor)).to be(true)
  end

  it 'offers nothing to another minor' do
    other = start_minor!(game, 'B', player, 'SP')
    game.minor_regional_order.delete(other)
    game.minor_regional_order.unshift(other)
    round = operating!

    expect(round.current_entity).to eq(other)
    expect(placements(other)).to be_empty
    expect(round.active_step.actions(other)).not_to include('assign')
  end

  it 'refuses a metropolis' do
    round = operating!
    action = Engine::Action::Assign.new(minor, target: game.hex_by_id('Q30'))

    expect { act!(round, action) }.to raise_error(Engine::GameError, /Green Junction/)
  end

  it 'adds £20 to the holder\'s trains run to or through the city, nothing to others (§15.4)' do
    game.green_junction_place!(minor, nancy)
    other = start_minor!(game, 'B', player, 'SP')

    expect(game.green_junction_revenue(route(minor, [game.hex_by_id('W64'), nancy]))).to eq(20)
    expect(game.green_junction_revenue(route(minor, [game.hex_by_id('W64')]))).to eq(0)
    expect(game.green_junction_revenue(route(other, [nancy]))).to eq(0)
  end

  it 'adds the bonus to a real route of the holder and names it (§15.4)' do
    tile = game.tiles.find { |t| t.name == 'OE33' && !t.hex }
    game.hex_by_id('N31').lay(tile)
    lille = game.hex_by_id('N31').tile.cities.first
    lille.place_token(minor, minor.next_token, free: true, check_tokenable: false)
    train = game.trains.find { |t| t.name == '2+2' && !t.owner.is_a?(Engine::Corporation) }
    game.buy_train(minor, train, :free)
    game.graph.clear
    build = lambda do
      Engine::Route.new(game, game.phase, train, routes: []).tap do |r|
        r.routes = [r]
        [game.hex_by_id('M28').tile.cities.first, lille].each { |node| r.touch_node(node) }
      end
    end
    base = build.call.revenue

    game.green_junction_place!(minor, game.hex_by_id('N31'))
    route = build.call

    expect(route.revenue).to eq(base + 20)
    expect(game.revenue_str(route)).to include('Green Junction')
  end

  it 'doubles the bonus for a "D" train (§11.3.9)' do
    game.green_junction_place!(minor, nancy)

    expect(game.green_junction_revenue(route(minor, [nancy], multiplier: 2))).to eq(40)
  end

  it 'removes the £20 token at the start of Phase 5; a £40 token may then be placed anew' do
    game.green_junction_place!(minor, nancy)
    at_phase!(game, '5')

    expect(game.green_junction_hex).to be_nil
    expect(nancy.assigned?('D')).to be(false)
    expect(game.green_junction_placeable?(minor)).to be(true)

    beograd = game.hex_by_id('W64')
    game.green_junction_place!(minor, beograd)
    expect(game.green_junction_revenue(route(minor, [beograd]))).to eq(40)
    expect(game.green_junction_placeable?(minor)).to be(false)

    at_phase!(game, '6')
    expect(game.green_junction_hex).to eq(beograd)
  end

  it 'pays £40 for a token first placed in Phase 5 or later' do
    at_phase!(game, '5')
    game.green_junction_place!(minor, nancy)

    expect(game.green_junction_revenue(route(minor, [nancy]))).to eq(40)
  end

  it 'moves with the charter into the major it merges into' do
    major = start_major!(game, 'LNWR', player)
    game.green_junction_place!(minor, nancy)
    game.add_minor_charter!(minor, major)

    expect(game.green_junction_revenue(route(major, [nancy]))).to eq(20)
    at_phase!(game, '5')
    expect(game.green_junction_placeable?(major)).to be(true)
    expect(game.green_junction_placeable?(minor)).to be(false)
  end

  it 'goes back to the charter when the minor is abandoned (§9.5)' do
    game.green_junction_place!(minor, nancy)
    game.abandon_minor!(minor)

    expect(game.green_junction_hex).to be_nil
    expect(nancy.assigned?('D')).to be(false)
    expect(game.green_junction_placeable?(minor)).to be(true)
  end
end
