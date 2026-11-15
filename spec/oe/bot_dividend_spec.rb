# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/bot"

# #327 (rule 3 of #140 via #311): Bot::Dividend pays half when the share value
# still moves RIGHT, keeps cash while the next level's train is missing, and lets
# regionals keep or pay without market consequences. The share price outcome is
# the engine's own (Dividend#dividend_options).
RSpec.describe Oe::Bot::Dividend do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:president) { game.players[0] }
  let(:step) { Engine::Game::G18OE::Step::Dividend.new(game, []) }
  let(:dividend) { described_class.new(game, Random.new(1)) }

  before { allow(dividend).to receive(:engine_step).and_return(step) }

  def major_at(price, cash:)
    major = start_major!(game, "LNWR", president)
    game.stock_market.move(major, cell(game, price).coordinates)
    major.spend(major.cash, game.bank) if major.cash.positive?
    fund!(game, major, cash) if cash.positive?
    major
  end

  def regional_with(cash:)
    regional = start_regional!(game, "KSS", president)
    regional.spend(regional.cash, game.bank) if regional.cash.positive?
    fund!(game, regional, cash) if cash.positive?
    regional
  end

  def give_train!(entity, name)
    train = game.depot.upcoming.find { |t| t.name == name }
    game.buy_train(entity, train, :free)
    train
  end

  def revenue!(amount, entity)
    allow(step).to receive(:current_entity).and_return(entity)
    allow(step).to receive(:total_revenue).and_return(amount)
  end

  def first_choice(entity)
    dividend.ranking(entity).first
  end

  def actions(entity, kinds = %w[withhold half payout])
    kinds.map { |kind| Engine::Action::Dividend.new(entity, kind: kind) }
  end

  describe "engine share price outcome used for 'half'" do
    it "moves RIGHT on half when the paid-out half reaches the share value (RB 4.4 example: £150, £320)" do
      major = major_at(150, cash: 0)
      revenue!(320, major)
      expect(step.dividend_options(major)[:half][:share_direction]).to eq(:right)
    end

    it "does not move on half below the share value (RB 4.4 example: £165, £320)" do
      major = major_at(165, cash: 0)
      revenue!(320, major)
      expect(step.dividend_options(major)[:half][:share_direction]).to be_nil
      expect(step.dividend_options(major)[:payout][:share_direction]).to eq(:right)
    end
  end

  describe "major" do
    it "pays out when it owns a train of the level on sale" do
      major = major_at(100, cash: 0)
      give_train!(major, "2+2")
      revenue!(120, major)
      expect(first_choice(major)).to eq("payout")
    end

    it "pays out when its cash already covers the train on sale" do
      major = major_at(100, cash: 150)
      revenue!(120, major)
      expect(first_choice(major)).to eq("payout")
    end

    it "pays half when it needs cash and half still moves the share value RIGHT" do
      major = major_at(150, cash: 0)
      revenue!(320, major)
      expect(first_choice(major)).to eq("half")
    end

    it "pays half (price stays) when it needs cash and the retained half covers the train" do
      major = major_at(165, cash: 0)
      revenue!(320, major) # half = 160 retained >= 2+2 at 100, but 160 < 165: no RIGHT
      expect(first_choice(major)).to eq("half")
    end

    it "withholds when it needs cash and the half neither moves RIGHT nor covers the train" do
      major = major_at(100, cash: 0)
      revenue!(80, major) # half = 40 < 100 share value, 40 < 100 train price
      expect(first_choice(major)).to eq("withhold")
    end

    it "does not save for a train it has no room for" do
      major = major_at(100, cash: 0)
      allow(game).to receive(:train_limit).with(major).and_return(0)
      revenue!(80, major)
      expect(first_choice(major)).to eq("payout")
    end
  end

  describe "regional (no share value movement)" do
    it "withholds while it has no level-3 train and less cash than one costs" do
      regional = regional_with(cash: 0)
      give_train!(regional, "2+2")
      revenue!(80, regional)
      expect(first_choice(regional)).to eq("withhold")
    end

    it "pays out once its cash covers a level-3 train" do
      regional = regional_with(cash: 200)
      give_train!(regional, "2+2")
      expect(first_choice(regional)).to eq("payout")
    end

    it "pays out once it owns a level-3 train" do
      regional = regional_with(cash: 0)
      game.depot.upcoming.select { |t| t.name == "2+2" }.each { |t| game.depot.remove_train(t) }
      give_train!(regional, "3")
      expect(first_choice(regional)).to eq("payout")
    end
  end

  describe "#choose" do
    it "picks the first-ranked kind most of the time and the second now and then" do
      major = major_at(100, cash: 0)
      revenue!(80, major)
      picks = Array.new(400) { |i| described_class.new(game, Random.new(i)).tap { |d| allow(d).to receive(:engine_step).and_return(step) }.choose("Dividend" => actions(major)).kind }
      expect(picks.tally.keys).to contain_exactly("withhold", "half")
      expect(picks.count("withhold")).to be > 340
    end

    it "only returns an offered kind" do
      regional = regional_with(cash: 0)
      give_train!(regional, "2+2")
      picks = Array.new(50) { |i| described_class.new(game, Random.new(i)).choose("Dividend" => actions(regional, %w[payout])).kind }
      expect(picks.uniq).to eq(%w[payout])
    end

    it "is used by Oe::Bot instead of the StrategyPlayer fallback" do
      expect(Oe::Bot::FALLBACK_FIRST).not_to include("Dividend")
      bot = Oe::Bot.new(game, rng: Random.new(1))
      regional = regional_with(cash: 0)
      give_train!(regional, "2+2")
      allow(Oe::LegalActions).to receive(:new).and_return(double(call: actions(regional)))
      expect(bot.choose.kind).to eq("withhold").or eq("half")
      expect(bot.instance_variable_get(:@dividend)).to be_a(described_class)
    end
  end
end
