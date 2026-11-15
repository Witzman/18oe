# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE any available token may be placed (§11.2)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let(:major) { start_major!(game, 'LNWR', player) }
  let(:round) do
    major
    enter_round!(game, game.operating_round(1)).tap { act!(_1, Engine::Action::Pass.new(major)) }
  end
  let(:city) { game.hex_by_id('J25').tile.cities.first }
  let(:spare_tokens) { major.tokens.reject(&:city) }

  def place!(token)
    action = Engine::Action::PlaceToken.new(major, city: city, slot: 0)
    action.token = token
    act!(round, action)
  end

  it 'lists the spare tokens of a converted major with their charter prices (setup)' do
    expect(spare_tokens.map(&:price)).to eq([20, 40, 60, 60, 80, 80, 80])
  end

  it 'lets the railroad pick a dearer token than the next one in the charter row (§11.2)' do
    dear = spare_tokens.last
    cash = major.cash

    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::Token)
    place!(dear)

    expect(city.tokened_by?(major)).to be(true)
    expect(dear.city).to eq(city)
    expect(major.cash).to eq(cash - 80)
  end

  it 'leaves the cheaper tokens on the charter after that' do
    place!(spare_tokens.last)

    expect(major.tokens.reject(&:city).map(&:price)).to eq([20, 40, 60, 60, 80, 80])
  end

  it 'allows one token per operating round (§11.2)' do
    place!(spare_tokens.first)

    expect(round.active_step).not_to be_a(Engine::Game::G18OE::Step::Token)
  end

  it 'keeps the choice in the action record, so a replay places the same token (§11.2)' do
    pending 'deviation: PlaceToken serialises no token, a replay always takes the first unused token (workshop #346)'
    action = Engine::Action::PlaceToken.new(major, city: city, slot: 0)
    action.token = spare_tokens.last
    replayed = Engine::Action::Base.action_from_h(action.to_h, game)

    expect(replayed.token.price).to eq(80)
  end
end
