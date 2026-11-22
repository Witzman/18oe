# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# §11.6.4 para. 2 (RB l. 4629-4641): no paid track or token that drives a RR into
# first-round insolvency. Built as a guard instead of the rule's refund (workshop #352).
describe 'G18OE first-round spend guard (§11.6.4 para. 2)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:president) { game.players.first }
  # GSWR (home I20) can lay on I26 for £30 terrain and token J25 for £20 in its first OR; both lie across the Irish Sea
  # ferry from Dublin (distance 1), which adds £5 to the tile and £20 to the token (§11.1.6, §11.2.1, #61).
  let(:gswr) { start_regional!(game, 'GSWR', president) }
  let(:reserve) { 100 }

  def operating!
    gswr
    enter_round!(game, game.operating_round(1))
  end

  def lay!(round, hex_id)
    lay_first_legal!(game, round, hex_id)
  end

  def token!(round)
    act!(round, Engine::Action::PlaceToken.new(gswr, city: game.hex_by_id('J25').tile.cities.first, slot: 0))
  end

  def cash_total
    gswr.cash + president.cash
  end

  def legal(round)
    Oe::LegalActions.new(game).lay_tile_options(round.active_step, gswr).map { |hex, _| hex.id }
  end

  it 'reserves the price of the 2+2 (£100)' do
    operating!

    expect(game.first_round_train_reserve(gswr)).to eq(reserve)
  end

  # Premise of the guard: between Track/Token and BuyTrain the first OR adds no money.
  it 'adds no money to the RR or its president between Track/Token and BuyTrain in the first OR' do
    round = operating!
    gswr.set_cash(200, game.bank)
    president.set_cash(50, game.bank)
    lay!(round, 'I26')
    act!(round, Engine::Action::Pass.new(gswr)) if round.active_step.is_a?(Engine::Game::G18OE::Step::Track)
    token!(round)
    before = [gswr.cash, president.cash]

    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::BuyTrain)
    expect(round.current_entity).to eq(gswr)
    expect([gswr.cash, president.cash]).to eq(before)
    expect(before).to eq([125, 50]) # 200 less the lay (£30 + £5 ferry) and the token (£20 + £20 ferry)
  end

  context 'with a paid lay at the limit' do
    it 'allows the lay when exactly the 2+2 stays covered' do
      round = operating!
      gswr.set_cash(85, game.bank)
      president.set_cash(50, game.bank)

      expect(legal(round)).to include('I26')
      lay!(round, 'I26')
      expect(cash_total).to eq(reserve)
    end

    it 'refuses the lay one pound below, and the enumerator does not offer it' do
      round = operating!
      gswr.set_cash(84, game.bank)
      president.set_cash(50, game.bank)

      expect(legal(round)).not_to include('I26')
      expect { lay!(round, 'I26') }.to raise_error(Engine::GameError, /reserved 2\+2/)
    end

    it 'still allows free lays' do
      round = operating!
      gswr.set_cash(10, game.bank)
      president.set_cash(0, game.bank)

      expect(legal(round)).not_to be_empty
      expect(legal(round)).not_to include('I26', 'J23')
    end
  end

  it 'refuses the token after a paid lay used up the margin' do
    round = operating!
    gswr.set_cash(95, game.bank)
    president.set_cash(50, game.bank)
    lay!(round, 'I26')
    act!(round, Engine::Action::Pass.new(gswr)) if round.active_step.is_a?(Engine::Game::G18OE::Step::Track)

    expect(cash_total).to eq(110)
    # the token step has nothing to offer, so the round moves on to BuyTrain
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::BuyTrain)
    token_step = round_step(round, Engine::Game::G18OE::Step::Token)
    expect(token_step.can_place_token?(gswr)).to be(false)
    expect(Oe::LegalActions.new(game).token_targets(token_step, gswr)).to eq([])
  end

  it 'refuses a token placed directly when it would break the reserve' do
    round = operating!
    gswr.set_cash(60, game.bank)
    president.set_cash(55, game.bank)
    act!(round, Engine::Action::Pass.new(gswr))
    token_step = round_step(round, Engine::Game::G18OE::Step::Token)

    expect(token_step.can_place_token?(gswr)).to be(false)
    expect do
      token_step.place_token(gswr, game.hex_by_id('J25').tile.cities.first, gswr.next_token)
    end.to raise_error(Engine::GameError, /reserved 2\+2/)
    expect(gswr.cash).to eq(60)
  end

  it 'does not guard once the 2+2 obligation is fulfilled' do
    round = operating!
    gswr.set_cash(45, game.bank)
    president.set_cash(0, game.bank)
    game.fulfill_train_obligation!(gswr)

    expect(game.first_round_train_reserve(gswr)).to be_nil
    expect(legal(round)).to include('I26')
    lay!(round, 'I26')
    expect(gswr.cash).to eq(10)
  end

  it 'guards a major that still owes its 2+2 (regional converted before its first OR)' do
    major = start_major!(game, 'GSWR', president)
    round = enter_round!(game, game.operating_round(1))
    major.set_cash(79, game.bank)
    president.set_cash(50, game.bank)

    expect(major.type).to eq(:major)
    expect(game.first_round_train_reserve(major)).to eq(reserve)
    expect(Oe::LegalActions.new(game).lay_tile_options(round.active_step, major).map { |hex, _| hex.id }).not_to include('I26')
    expect { lay!(round, 'I26') }.to raise_error(Engine::GameError, /reserved 2\+2/)
  end

  it 'counts a patronage payout of the same lay against its cost' do
    # I26 (a town) never draws a patronage tile; set one by hand to isolate the arithmetic.
    game.hex_by_id('I26').tile.patronage = { yellow: 20, green: 30, brown: 40, gray: 50 }
    round = operating!
    gswr.set_cash(79, game.bank)
    president.set_cash(50, game.bank)

    expect(game.patronage_payout(game.hex_by_id('I26'))).to eq(20)
    expect(legal(round)).to include('I26')
    lay!(round, 'I26')
    expect(cash_total).to eq(114) # 129 less the lay (£30 + £5 ferry) plus the patronage payout of £20
  end
end
