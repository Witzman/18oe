# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# #77 (§14.3): Wien Suedbahnhof places one token of a controlled RR for free (reachable as if paid, water fee stays).
describe 'G18OE Wien Suedbahnhof (§14.3)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:owner) { game.players[0] }
  let(:other) { game.players[1] }
  let(:ws) { give_company!(owner, game.company_by_id('WS')) }
  let(:operator) { start_major!(game, 'LNWR', owner) }
  let(:target) do
    game.hexes.flat_map { |hex| hex.tile.cities }.find do |city|
      city.tokens.compact.empty? && game.port_accesses(city).empty? && city != game.lille_city
    end
  end

  def token_step_round!(corporation = operator, phase: '2')
    at_phase!(game, phase)
    game.minor_regional_order.delete(corporation)
    game.minor_regional_order.unshift(corporation)
    round = enter_round!(game, game.operating_round(1))
    round.setup
    round_step(round, Engine::Step::Track).pass!
    round
  end

  def connect!(city)
    graph = game.token_graph_for_entity(operator)
    nodes = graph.connected_nodes(operator).merge(city => true)
    allow(graph).to receive(:connected_nodes).with(operator).and_return(nodes)
  end

  def place!(round, city, company = ws)
    act!(round, Engine::Action::PlaceToken.new(company, city: city, tokener: operator))
  end

  it 'offers the owner a place token action for a controlled RR' do
    ws
    round = token_step_round!

    expect(round_step(round, Engine::Step::SpecialToken).actions(ws)).to eq(['place_token'])
  end

  it 'offers nothing for a RR of another player' do
    ws
    foreign = start_major!(game, 'LNWR', other)
    round = token_step_round!(foreign)

    expect(round_step(round, Engine::Step::SpecialToken).actions(ws)).to eq([])
  end

  it 'places a token of the RR for free and takes the Place Token step' do
    ws
    round = token_step_round!
    connect!(target)
    cash = operator.cash
    unplaced = operator.unplaced_tokens.size

    place!(round, target)

    expect(target.tokened_by?(operator)).to be(true)
    expect(operator.cash).to eq(cash)
    expect(operator.unplaced_tokens.size).to eq(unplaced - 1)
    expect(round.tokened).to be(true)
  end

  it 'keeps the token price of the placed token' do
    ws
    round = token_step_round!
    connect!(target)
    token = operator.next_token
    price = token.price

    place!(round, target)

    expect(token.price).to eq(price)
  end

  it 'removes the private from the game after use (§6.1)' do
    ws
    round = token_step_round!
    connect!(target)

    place!(round, target)

    expect(ws).to be_closed
    expect(owner.companies).not_to include(ws)
  end

  it 'needs a connection, as if the token were paid' do
    ws
    round = token_step_round!

    expect { place!(round, target) }.to raise_error(Engine::GameError, /not connected/)
  end

  it 'still charges the fee for the ferries and sea zones (§11.2.1)' do
    ws
    round = token_step_round!
    connect!(target)
    cost = Struct.new(:ferries, :zones).new(1, 1)
    allow(game).to receive(:cross_water_token_cost).and_return(cost)
    fee = game.cross_water_fee_of(cost, :token)
    expect(fee).to be_positive
    fund!(game, operator, 200)
    cash = operator.cash

    place!(round, target)

    expect(operator.cash).to eq(cash - fee)
  end

  it 'refuses the token when the RR cannot pay the fee' do
    ws
    round = token_step_round!
    connect!(target)
    cost = Struct.new(:ferries, :zones).new(1, 1)
    allow(game).to receive(:cross_water_token_cost).and_return(cost)
    operator.spend(operator.cash, game.bank) if operator.cash.positive?

    expect { place!(round, target) }.to raise_error(Engine::GameError, /cannot pay/)
  end

  it 'is enumerated only for connected cities, and every offered action is accepted' do
    ws
    round = token_step_round!
    connect!(target)
    places = Oe::LegalActions.new(game).call.select { |a| a.is_a?(Engine::Action::PlaceToken) && a.entity == ws }

    graph = game.token_graph_for_entity(operator)
    expect(places.map(&:city)).to include(target)
    expect(places.map(&:city)).to all(satisfy { |city| graph.connected_nodes(operator)[city] })
    expect { act!(round, places.first) }.not_to raise_error
  end

  describe 'with the White Cliffs Ferry (§14.3, §14.7)' do
    let(:wcf) { give_company!(owner, game.company_by_id('WCF')) }
    let(:lille) { game.lille_city }

    def wcf_place!(round, cost: nil)
      act!(round, Engine::Action::PlaceToken.new(wcf, city: lille, tokener: operator, cost: cost))
    end

    it 'pays the ferry token when the owner names the Wien Suedbahnhof (cost 0)' do
      ws
      wcf
      round = token_step_round!(phase: '5')
      cash = operator.cash

      wcf_place!(round, cost: 0)

      expect(lille.extra_tokens.map(&:corporation)).to include(operator)
      expect(operator.cash).to eq(cash)
      expect(ws).to be_closed
      expect(wcf).to be_closed
    end

    it 'charges the RR when no payment by the Wien Suedbahnhof is named' do
      ws
      wcf
      round = token_step_round!(phase: '5')
      fund!(game, operator, 200)
      cash = operator.cash

      wcf_place!(round)

      expect(operator.cash).to be < cash
      expect(ws).not_to be_closed
    end

    it 'refuses the free ferry token without the Wien Suedbahnhof' do
      wcf
      round = token_step_round!(phase: '5')

      expect { wcf_place!(round, cost: 0) }.to raise_error(Engine::GameError, /Wien/)
    end
  end
end
