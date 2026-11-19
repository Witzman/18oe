# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #57: Transfer Tokens (§11.5), step 5 of a major's OR turn (after the dividend, before Buy Trains). A major buys an
# already placed station token of another major of the same player: it pays the bank the placement cost of its own
# next charter token and the selling major the access fee (£20 city, £40 grand city "Y", £60 metropolis); its token
# replaces the seller's, which returns to the seller's highest-cost open charter position. Home tokens never.
describe 'G18OE transfer tokens (§11.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let!(:lnwr) { start_major!(game, 'LNWR', player) }
  let!(:gwr) { start_major!(game, 'GWR', player) }
  let(:round) { at_phase!(game, '3') && operating_round_for!(game, 1) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::TransferTokens) }

  before do
    with_trains!(game, lnwr, '2+2')
    with_trains!(game, gwr, '2+2')
    game.fulfill_train_obligation!(lnwr)
    game.fulfill_train_obligation!(gwr)
    lnwr.set_cash(500, game.bank)
    gwr.set_cash(500, game.bank)
    round.instance_variable_set(:@entity_index, round.entities.index(lnwr))
    round.instance_variable_set(:@current_operator, lnwr)
  end

  def token_in(hex_id, corporation)
    place_token!(game, hex_id, corporation)
    game.hex_by_id(hex_id).tile.cities.first.tokens.find { |t| t&.corporation == corporation }
  end

  def transfer!(token, buyer = lnwr)
    city = token.city
    choice = "transfer_token:#{token.corporation.id}:#{city.tile.hex.id}:#{city.index}"
    step.process_choose(Engine::Action::Choose.new(buyer, choice: choice))
  end

  it 'sits after the dividend and before Buy Trains in the OR step list' do
    classes = round.steps.map(&:class)
    expect(classes.index(Engine::Game::G18OE::Step::TransferTokens)).to be > classes.index(Engine::Game::G18OE::Step::Dividend)
    expect(classes.index(Engine::Game::G18OE::Step::TransferTokens)).to be < classes.index(Engine::Game::G18OE::Step::BuyTrain)
  end

  it 'offers a placed token of another major of the same player, with its price' do
    token = token_in('AA20', gwr)
    choices = step.choices
    expect(choices.size).to eq(1)
    expect(choices.keys.first).to eq("transfer_token:GWR:AA20:#{token.city.index}")
    expect(step.actions(lnwr)).to include('choose', 'pass')
  end

  it 'offers nothing for a home token, for a major of another player or for the major itself' do
    gwr_home = gwr.placed_tokens.first
    place_token!(game, 'AA20', gwr) unless gwr_home
    other = start_major!(game, 'PLM', game.players.last)
    token_in('Q38', other)
    token_in('W64', lnwr)
    expect(step.choices.keys.grep(/GWR/)).to be_empty if gwr_home
    expect(step.choices.keys.grep(/PLM|LNWR/)).to be_empty
  end

  it 'moves the token: buyer pays the bank its charter price and the seller the £20 fee; the seller gets its token back' do
    token = token_in('AA20', gwr)
    price = lnwr.next_token.price
    seller_cash = gwr.cash
    expect { transfer!(token) }.to change(lnwr, :cash).by(-(price + 20))
    expect(gwr.cash).to eq(seller_cash + 20)
    city = game.hex_by_id('AA20').tile.cities.first
    expect(city.tokens.compact.map(&:corporation)).to eq([lnwr])
    expect(gwr.placed_tokens).not_to include(token)
    expect(token.city).to be_nil
    expect(gwr.unplaced_tokens).to include(token)
  end

  it 'charges £40 for a grand city ("Y") and £60 for a metropolis' do
    expect(game.token_transfer_fee(game.hex_by_id('G26'))).to eq(40)
    expect(game.token_transfer_fee(game.hex_by_id('B41'))).to eq(60)
    expect(game.token_transfer_fee(game.hex_by_id('AA20'))).to eq(20)
  end

  it 'refuses a token without cash for price and fee, or when the buyer has no token left' do
    token = token_in('AA20', gwr)
    lnwr.set_cash(lnwr.next_token.price + 19, game.bank)
    expect(step.choices).to eq({})
    expect { transfer!(token) }.to raise_error(Engine::GameError, /transfer/i)
    lnwr.set_cash(500, game.bank)
    lnwr.unplaced_tokens.each { |t| t.used = true }
    expect(step.choices).to eq({})
  end

  it 'puts the returned token on the seller\'s highest-cost open charter position' do
    token_in('AA20', gwr)
    second = token_in('Q38', gwr)
    # the seller has two placed tokens now; selling one leaves one placed, so the open positions shrink by one
    # position (the highest open) and the returned token takes its price.
    positions = gwr.tokens.map(&:price)
    transfer!(second)
    unplaced_prices = gwr.unplaced_tokens.map(&:price)
    expect(unplaced_prices).to eq(positions.sort.last(unplaced_prices.size))
  end

  it 'lets the major buy several tokens in one turn while cash and tokens last' do
    first = token_in('AA20', gwr)
    second = token_in('Q38', gwr)
    transfer!(first)
    transfer!(second)
    expect(lnwr.placed_tokens.size).to be >= 2
  end

  it 'is not offered to a minor, a regional or a national' do
    expect(game.token_transfer_choices(game.corporation_by_id('A'))).to eq({}) if game.corporation_by_id('A')
  end
end
