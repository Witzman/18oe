# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE dividends (§11.4, §4.4)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:step) { Engine::Game::G18OE::Step::Dividend.new(game, []) }
  let(:president) { game.players[0] }
  let(:other) { game.players[1] }
  let(:regional) { start_regional!(game, 'KSS', president) }
  let(:minor) { start_minor!(game, 'K', president, 'RU') }

  def major_at(price)
    major = start_major!(game, 'LNWR', president)
    game.stock_market.move(major, cell(game, price).coordinates)
    major
  end

  def types_for(entity)
    allow(step).to receive(:current_entity).and_return(entity)
    step.dividend_types
  end

  def split_regional!
    take_treasury_shares!(game, other, regional, 1)
    regional
  end

  it 'gives each railroad type its own dividend choices (§11.4)' do
    national = regional.dup.tap { |c| c.type = :national }

    expect(types_for(minor)).to eq(%i[half withhold])
    expect(types_for(regional)).to eq(%i[withhold half payout])
    expect(types_for(major_at(75))).to eq(%i[withhold half payout])
    expect(types_for(national)).to eq(%i[payout withhold])
  end

  it 'never asks a minor to choose' do
    expect(step.actions(minor)).to eq([])
  end

  it 'pays out the §11.4 GWR example: £70 to 50%, 25% and a treasury 25%' do
    split_regional!
    per_share = step.payout(regional, 70)[:per_share]

    expect(step.dividends_for_entity(regional, president, per_share)).to eq(35)
    expect(step.dividends_for_entity(regional, other, per_share)).to eq(18)
    expect(step.dividends_for_entity(regional, regional, per_share)).to eq(18)
  end

  it 'half pays the §11.4 KSS example: treasury £44, £18 and £9' do
    split_regional!
    half = step.half(regional, 70)

    expect(half[:corporation] + step.dividends_for_entity(regional, regional, half[:per_share])).to eq(44)
    expect(step.dividends_for_entity(regional, president, half[:per_share])).to eq(18)
    expect(step.dividends_for_entity(regional, other, half[:per_share])).to eq(9)
  end

  it 'half pays the §11.4 Minor K example: £25 each' do
    half = step.half(minor, 50)

    expect(half[:corporation]).to eq(25)
    expect(step.dividends_for_entity(minor, president, half[:per_share])).to eq(25)
  end

  it 'never moves minors or regionals on the market' do
    expect(step.share_price_change(regional, 500)).to eq({})
    expect(step.share_price_change(minor, 500)).to eq({})
  end

  it 'moves a major LEFT when it pays nothing (§4.4)' do
    expect(step.share_price_change(major_at(75), 0)).to eq(share_direction: :left, share_times: 1)
  end

  it 'moves a major RIGHT when it pays exactly its share value (§4.4)' do
    expect(step.share_price_change(major_at(75), 75)).to eq(share_direction: :right, share_times: 1)
  end

  it 'leaves a major in place when it pays less than its share value (§4.4)' do
    expect(step.share_price_change(major_at(75), 74)).to eq({})
  end

  it 'moves a £150 major RIGHT on a £160 half payout of £320 (§4.4 example)' do
    major = major_at(150)
    paid = 320 - step.half(major, 320)[:corporation]

    expect(step.share_price_change(major, paid)).to eq(share_direction: :right, share_times: 1)
  end

  it 'leaves a £165 major in place on a £160 payout (§4.4 example)' do
    expect(step.share_price_change(major_at(165), 160)).to eq({})
  end

  it 'withholds automatically for a minor that earned nothing' do
    minor
    round = enter_round!(game, game.operating_round(1))
    round_step(round, Engine::Game::G18OE::Step::Dividend).skip!

    expect(minor.operating_history[[game.turn, 1]].dividend.kind).to eq('withhold')
  end
end

# #419: the marker really moves on the market when a dividend is processed (§4.2, §4.4, §11.4),
# per railroad type and per dividend choice, through the OR's own Dividend step.
describe 'G18OE share value marker after a dividend (§4.4, #419)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:president) { game.players[0] }
  let(:round) { operating_round_for!(game) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::Dividend) }

  def at(corporation, price)
    game.stock_market.move(corporation, cell(game, price).coordinates)
    corporation
  end

  def major_at(price, id = 'LNWR')
    at(start_major!(game, id, president), price)
  end

  def national_at(price)
    major_at(price, 'PLM').tap { |c| c.type = :national }
  end

  def pay!(entity, revenue, kind)
    allow(step).to receive(:current_entity).and_return(entity)
    allow(step).to receive(:total_revenue).and_return(revenue)
    step.process_dividend(Engine::Action::Dividend.new(entity, kind: kind))
    entity
  end

  def price_after(entity, revenue, kind)
    pay!(entity, revenue, kind).share_price.price
  end

  describe 'a major' do
    it 'moves RIGHT on a full payout equal to its share value' do
      expect(price_after(major_at(150), 150, 'payout')).to eq(165)
    end

    it 'stays on a full payout below its share value' do
      expect(price_after(major_at(150), 140, 'payout')).to eq(150)
    end

    it 'moves RIGHT on a half payout whose paid half reaches its share value (§4.4 example)' do
      expect(price_after(major_at(150), 320, 'half')).to eq(165)
    end

    it 'stays on a half payout whose paid half is below its share value (§4.4 example)' do
      expect(price_after(major_at(165), 320, 'half')).to eq(165)
    end

    it 'moves LEFT when it withholds' do
      expect(price_after(major_at(150), 320, 'withhold')).to eq(135)
    end

    it 'moves LEFT when it pays nothing because it earned nothing' do
      expect(price_after(major_at(150), 0, 'payout')).to eq(135)
    end

    it 'moves UP when it cannot move RIGHT (£490 at the end of the second row)' do
      major = major_at(150)
      game.stock_market.move(major, [1, 18])
      expect(major.share_price.price).to eq(490)
      pay!(major, 500, 'payout')
      expect(major.share_price.coordinates).to eq([0, 18])
      expect(major.share_price.price).to eq(550)
    end

    it 'does not move from £550' do
      expect(price_after(major_at(550), 600, 'payout')).to eq(550)
    end

    it 'moves DOWN when it cannot move LEFT (£110 in the top row)' do
      major = major_at(150)
      game.stock_market.move(major, [0, 3])
      expect(major.share_price.price).to eq(110)
      pay!(major, 0, 'withhold')
      expect(major.share_price.coordinates).to eq([1, 3])
      expect(major.share_price.price).to eq(100)
    end

    it 'does not move from £30, the bottom left field of the board' do
      major = major_at(30)
      expect(major.share_price.coordinates).to eq([8, 0])
      expect(price_after(major, 0, 'withhold')).to eq(30)
    end
  end

  describe 'a national' do
    it 'pays out and moves RIGHT when the payout reaches its share value' do
      expect(price_after(national_at(100), 100, 'payout')).to eq(110)
    end

    it 'stays when the payout is below its share value' do
      expect(price_after(national_at(100), 90, 'payout')).to eq(100)
    end

    it 'moves LEFT when it earns nothing (the step withholds for it)' do
      national = national_at(100)
      allow(step).to receive(:current_entity).and_return(national)
      allow(step).to receive(:total_revenue).and_return(0)
      step.skip!
      expect(national.share_price.price).to eq(90)
    end

    it 'cannot pay half' do
      allow(step).to receive(:current_entity).and_return(national_at(100))
      expect(step.dividend_types).not_to include(:half)
    end
  end

  describe 'a regional (stays on its par value)' do
    let(:regional) { start_regional!(game, 'KSS', president, par: 60) }

    %w[payout half withhold].each do |kind|
      it "keeps its par value on #{kind}" do
        par = regional.share_price
        pay!(regional, kind == 'withhold' ? 0 : 500, kind)
        expect(regional.share_price).to eq(par)
      end
    end
  end

  describe 'a minor (has no share value)' do
    let(:minor) { start_minor!(game, 'K', president, 'RU') }

    %w[half withhold].each do |kind|
      it "has no market marker after #{kind}" do
        before = minor.share_price
        pay!(minor, kind == 'withhold' ? 0 : 80, kind)
        expect(minor.share_price).to eq(before)
        expect(game.stock_market.market.flatten.compact.any? { |sp| sp.corporations.include?(minor) }).to be(false)
      end
    end
  end
end

# #486 (owner decision of 2026-11-19, #485 option A): half pay on an odd revenue. The treasury gets
# floor(revenue / 2), the shareholders the rest, and every recipient is rounded UP to the next £1 after its
# own share is computed (Rulebook §11.4, "rounding up to the nearest £1 after calculating the percentage
# for each recipient"). A £1 rounding surplus therefore comes from the bank, never from the treasury's half.
describe 'G18OE half dividend on an odd revenue (§11.4, #486)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:president) { game.players[0] }
  let(:other) { game.players[1] }
  let(:third) { game.players[2] }
  let(:round) { operating_round_for!(game) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::Dividend) }

  def major_at(price)
    major = start_major!(game, 'LNWR', president)
    game.stock_market.move(major, cell(game, price).coordinates)
    major
  end

  def pay!(entity, revenue, kind)
    allow(step).to receive(:current_entity).and_return(entity)
    allow(step).to receive(:total_revenue).and_return(revenue)
    step.process_dividend(Engine::Action::Dividend.new(entity, kind: kind))
  end

  # Cash change of the given holders (and the bank) caused by one dividend.
  def deltas(entity, holders, revenue, kind)
    all = holders + [entity]
    before = all.to_h { |h| [h, h.cash] }
    bank_before = game.bank.cash
    pay!(entity, revenue, kind)
    all.to_h { |h| [h, h.cash - before[h]] }.merge(bank: bank_before - game.bank.cash)
  end

  describe 'a major' do
    it 'withholds floor(301 / 2) = £150, pays the other £151 and moves RIGHT at £150' do
      major = major_at(150)
      expect(step.half(major, 301)[:corporation]).to eq(150)

      delta = deltas(major, [president], 301, 'half')

      # president 20% of £15.10 per share-percent block = £30.20 -> £31; treasury 80% -> £120.80 -> £121
      expect(delta[president]).to eq(31)
      expect(delta[major]).to eq(150 + 121)
      expect(major.share_price.price).to eq(165)
    end

    it 'counts only the paid £151, not the £301 revenue: a £165 major stays' do
      major = major_at(165)

      pay!(major, 301, 'half')

      expect(major.share_price.price).to eq(165)
    end

    it 'rounds every recipient up on its own (20% and 10% player, 70% treasury)' do
      major = major_at(150)
      take_treasury_shares!(game, other, major, 1)

      delta = deltas(major, [president, other], 301, 'half')

      expect(delta[president]).to eq(31) # 20% of 151 = 30.2
      expect(delta[other]).to eq(16)     # 10% of 151 = 15.1
      expect(delta[major]).to eq(150 + 106) # 70% of 151 = 105.7; the withheld £150 is untouched
    end

    it 'pays the rounding surplus out of the bank, not out of the treasury half' do
      major = major_at(150)
      take_treasury_shares!(game, other, major, 1)

      delta = deltas(major, [president, other], 301, 'half')
      paid_to_holders = delta[president] + delta[other] + (delta[major] - 150)

      expect(paid_to_holders).to eq(31 + 16 + 106)
      expect(paid_to_holders).to be > 151
      expect(delta[:bank]).to eq(150 + paid_to_holders) # the bank covers the £2 over £301
      expect(delta[major]).to be >= 150                  # the treasury keeps its full floor half
    end

    it 'leaves an even revenue exact: £300 gives £150 to the treasury and £150 split without surplus' do
      major = major_at(150)
      take_treasury_shares!(game, other, major, 1)

      delta = deltas(major, [president, other], 300, 'half')

      expect(delta[president]).to eq(30)
      expect(delta[other]).to eq(15)
      expect(delta[major]).to eq(150 + 105)
      expect(delta[:bank]).to eq(300)
      expect(major.share_price.price).to eq(165)
    end
  end

  describe 'a minor (§11.4 Example 1: Minor K)' do
    let(:minor) { start_minor!(game, 'K', president, 'RU') }

    it 'pays £25 / £25 on an even £50' do
      delta = deltas(minor, [president], 50, 'half')

      expect(delta[minor]).to eq(25)
      expect(delta[president]).to eq(25)
    end

    it 'withholds floor(51 / 2) = £25 and pays the player the other £26 on an odd £51' do
      expect(step.half(minor, 51)[:corporation]).to eq(25)

      delta = deltas(minor, [president], 51, 'half')

      expect(delta[minor]).to eq(25)
      expect(delta[president]).to eq(26)
      expect(delta[:bank]).to eq(51)
    end

    it 'keeps the whole odd revenue on withhold' do
      delta = deltas(minor, [president], 51, 'withhold')

      expect(delta[minor]).to eq(51)
      expect(delta[president]).to eq(0)
    end
  end
end
