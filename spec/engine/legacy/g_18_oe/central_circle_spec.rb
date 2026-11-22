# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# #80 (§14.6, shared paragraphs of §14.5): the Central Circle token is a pass-through token.
describe 'G18OE Central Circle Transport (§14.6)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:owner) { game.players[0] }
  let(:other) { game.players[1] }
  let(:cctc) { give_company!(owner, game.company_by_id('CCTC')) }
  let(:operator) { start_major!(game, 'LNWR', owner) }
  let(:lille) { game.lille_city }

  def token_step_round!(game, operator)
    game.minor_regional_order.delete(operator)
    game.minor_regional_order.unshift(operator)
    round = enter_round!(game, game.operating_round(1))
    round.setup
    round_step(round, Engine::Step::Track).pass!
    round
  end

  def special_token(round)
    round_step(round, Engine::Step::SpecialToken)
  end

  def place!(round, city, company = cctc)
    act!(round, Engine::Action::PlaceToken.new(company, city: city, tokener: operator))
  end

  def pass_token_in(city)
    city.extra_tokens.find { |t| t.type == :pass }
  end

  def all_cities
    game.hexes.flat_map { |hex| hex.tile.cities }
  end

  def a_city
    all_cities.find { |city| game.port_accesses(city).empty? && city != lille && city.tokens.compact.empty? }
  end

  def a_port_city
    all_cities.find { |city| game.port_accesses(city).any? && city.tokens.compact.empty? }
  end

  it 'offers the owner a place token action for a controlled RR in the Place Token step' do
    cctc
    round = token_step_round!(game, operator)

    expect(special_token(round).actions(cctc)).to eq(['place_token'])
  end

  it 'offers nothing for a RR the owner does not control' do
    foreign = start_major!(game, 'LNWR', other)
    cctc
    round = token_step_round!(game, foreign)

    expect(special_token(round).actions(cctc)).to eq([])
  end

  it 'places the token for free, in an extra position, and consumes no token position of the RR' do
    cctc
    round = token_step_round!(game, operator)
    city = a_city
    tokens = operator.tokens.size
    unplaced = operator.unplaced_tokens.size
    cash = operator.cash

    place!(round, city)

    expect(pass_token_in(city).corporation).to eq(operator)
    expect(city.tokens.compact).to be_empty
    expect(operator.cash).to eq(cash)
    expect(operator.tokens.size).to eq(tokens)
    expect(operator.unplaced_tokens.size).to eq(unplaced)
  end

  it 'leaves the Place Token step open for a normal token' do
    cctc
    round = token_step_round!(game, operator)

    place!(round, a_city)

    expect(round.tokened).to be(false)
  end

  it 'closes the private once used' do
    cctc
    round = token_step_round!(game, operator)

    place!(round, a_city)

    expect(cctc).to be_closed
    expect(owner.companies).not_to include(cctc)
  end

  it 'needs no connection to the city' do
    cctc
    round = token_step_round!(game, operator)
    far = a_city
    expect(game.token_graph_for_entity(operator).connected_nodes(operator)[far]).to be_falsey

    expect { place!(round, far) }.not_to raise_error
  end

  it 'refuses a port city (that is the Star Harbor token)' do
    cctc
    round = token_step_round!(game, operator)

    expect { place!(round, a_port_city) }.to raise_error(Engine::GameError, /port/)
  end

  it 'does not make the city a station of the RR for routes and token placement' do
    cctc
    round = token_step_round!(game, operator)
    city = a_city
    place!(round, city)

    expect(game.city_tokened_by?(city, operator)).to be(false)
    expect(game.graph.connected_nodes(operator)[city]).to be_falsey
  end

  it 'is not blocked by tokens of other RRs, though the city is full' do
    cctc
    round = token_step_round!(game, operator)
    city = a_city
    %w[PLM MZA CPT].first(city.normal_slots).each do |id|
      other_rr = game.corporation_by_id(id)
      city.place_token(other_rr, other_rr.next_token, free: true, check_tokenable: false)
    end
    expect(city.blocks?(operator)).to be(true)

    place!(round, city)

    expect(city.blocks?(operator)).to be(false)
  end

  it 'does not count the city as a stop for the trains of the RR' do
    cctc
    round = token_step_round!(game, operator)
    city = a_city
    place!(round, city)
    train = with_trains!(game, operator, '2+2').first
    route = Engine::Route.new(game, game.phase, train, routes: [])
    route.routes = [route]
    london = game.hex_by_id('M28').tile.cities.first
    chain = { nodes: [london, city], paths: [] }
    allow(route).to receive(:connection_data).and_return([{ left: london, right: city, chain: chain }])

    expect(game.visited_stops(route)).to eq([london])
  end

  it 'keeps Lille passable for the RR (ferry access, §11.2.2)' do
    cctc
    round = token_step_round!(game, operator)
    blocker = game.corporation_by_id('PLM')
    lille.place_token(blocker, blocker.next_token, free: true, check_tokenable: false)
    expect(game.wcf_restricted?(operator)).to be_truthy

    place!(round, lille)

    expect(game.wcf_restricted?(operator)).to be_falsey
  end

  it 'is enumerated for non-port cities only, and every offered action is accepted' do
    cctc
    round = token_step_round!(game, operator)
    places = Oe::LegalActions.new(game).call.select { |a| a.is_a?(Engine::Action::PlaceToken) && a.entity == cctc }

    expect(places).not_to be_empty
    expect(places.map(&:city).map { |city| game.port_accesses(city).any? }.uniq).to eq([false])
    expect { act!(round, places.sample) }.not_to raise_error
  end

  # #487: the owner's free token (price 0, special_only) is the private's own token, not a discount on the RR's
  # own token: the Place Token step prices and offers the RR's tokens as before.
  describe 'the RR\'s own Place Token step while the owner holds the private (#487)' do
    let(:token_step) { Engine::Game::G18OE::Step::Token }

    it 'prices the RR\'s token at its own price, not at the private\'s free token' do
      cctc
      round = token_step_round!(game, operator)
      step = round_step(round, token_step)

      expect(step.min_token_price(step.available_tokens(operator))).to eq(operator.next_token.price)
    end

    it 'refuses a token whose price plus the sea fee the treasury cannot pay (Step#check_connected)' do
      cctc
      round = token_step_round!(game, operator)
      step = round_step(round, token_step)
      city = all_cities.find { |c| game.cross_water_token_fee(operator, c).to_i.positive? }
      skip 'no city with a sea fee reachable in this state' unless city

      operator.spend(operator.cash - (operator.next_token.price + game.cross_water_token_fee(operator, city)) + 1, game.bank)

      expect { step.check_connected(operator, city, city.hex) }.to raise_error(Engine::GameError, /cannot pay/)
    end
  end
end
