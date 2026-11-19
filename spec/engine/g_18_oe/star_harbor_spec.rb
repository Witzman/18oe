# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# #79 (§14.5, shared paragraphs with §14.6): the Star Harbor token is a pass-through token in a port city that
# also works as a port token (§11.3.4, §11.3.6).
describe 'G18OE Star Harbor Trading Company (§14.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:owner) { game.players[0] }
  let(:other) { game.players[1] }
  let(:shtc) { give_company!(owner, game.company_by_id('SHTC')) }
  let(:operator) { start_major!(game, 'LNWR', owner) }
  let(:edinburgh) { game.hex_by_id('G26').tile.cities.first }

  def token_step_round!(corporation = operator)
    game.minor_regional_order.delete(corporation)
    game.minor_regional_order.unshift(corporation)
    round = enter_round!(game, game.operating_round(1))
    round.setup
    round_step(round, Engine::Step::Track).pass!
    round
  end

  def place!(round, city, company = shtc)
    act!(round, Engine::Action::PlaceToken.new(company, city: city, tokener: operator))
  end

  def all_cities
    game.hexes.flat_map { |hex| hex.tile.cities }
  end

  def a_port_city
    all_cities.find { |city| game.port_accesses(city).any? && city.tokens.compact.empty? }
  end

  def a_land_city
    all_cities.find { |city| game.port_accesses(city).empty? && city.tokens.compact.empty? }
  end

  it 'offers the owner a place token action for a controlled RR in the Place Token step' do
    shtc
    round = token_step_round!

    expect(round_step(round, Engine::Step::SpecialToken).actions(shtc)).to eq(['place_token'])
  end

  it 'places the token free in an extra position, without using a token position or the step' do
    shtc
    round = token_step_round!
    city = a_port_city
    unplaced = operator.unplaced_tokens.size
    cash = operator.cash

    place!(round, city)

    expect(city.extra_tokens.map(&:corporation)).to eq([operator])
    expect(city.tokens.compact).to be_empty
    expect(operator.unplaced_tokens.size).to eq(unplaced)
    expect(operator.cash).to eq(cash)
    expect(round.tokened).to be(false)
    expect(shtc).to be_closed
  end

  it 'needs no connection to the city' do
    shtc
    round = token_step_round!
    city = a_port_city
    expect(game.token_graph_for_entity(operator).connected_nodes(operator)[city]).to be_falsey

    expect { place!(round, city) }.not_to raise_error
  end

  it 'refuses a city without a port (that is the Central Circle token)' do
    shtc
    round = token_step_round!

    expect { place!(round, a_land_city) }.to raise_error(Engine::GameError, /port city/)
  end

  it 'is no station for routes and token placement, and no blocker for the RR' do
    shtc
    round = token_step_round!
    city = a_port_city
    place!(round, city)

    expect(game.city_tokened_by?(city, operator)).to be(false)
    expect(game.graph.connected_nodes(operator)[city]).to be_falsey
    expect(city.blocks?(operator)).to be(false)
  end

  it 'makes the private Edinburgh port usable for the RR (§11.3.6)' do
    shtc
    round = token_step_round!
    access = game.port_accesses(edinburgh).find { |a| a.exit == :offshore }
    expect(game.usable_port_access?(edinburgh, access, operator)).to be(false)

    place!(round, edinburgh)

    expect(game.usable_port_access?(edinburgh, access, operator)).to be(true)
  end

  it 'works as a port token: it takes a sea unit off a crossing next to the city (§11.3.5)' do
    shtc
    round = token_step_round!
    place!(round, edinburgh)
    route = Struct.new(:corporation, :phase, :paths, :chains).new(operator, game.phase, [], [{ nodes: [edinburgh] }])

    expect(game.port_token_reducers(route).map(&:hex_ids)).to eq([['G26']])
  end

  it 'is enumerated for port cities only, and every offered action is accepted' do
    shtc
    round = token_step_round!
    places = Oe::LegalActions.new(game).call.select { |a| a.is_a?(Engine::Action::PlaceToken) && a.entity == shtc }

    expect(places).not_to be_empty
    expect(places.map(&:city).map { |city| game.port_accesses(city).any? }.uniq).to eq([true])
    expect { act!(round, places.sample) }.not_to raise_error
  end
end
