# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/strategy_player"
require "oe/bot"

# #421 (after #354, §11.6.4): the strategy player and the bot in a forced train purchase of a major.
# The president may not sell shares any more; he pays the difference from his own cash, and a major
# whose treasury and president cannot pay converts into a national (action `bankrupt`).
RSpec.describe "Strategy player and bot in a forced train purchase (§11.6.4, #421)" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:alice) { game.players[0] }
  let!(:lnwr) { start_major!(game, "LNWR", alice) }
  let(:round) { at_phase!(game, "4") && operating_round_for!(game, 1) }

  def operate!(corporation)
    round.instance_variable_set(:@entity_index, round.entities.index(corporation))
    round.instance_variable_set(:@current_operator, corporation)
    round.steps.each do |s|
      break if s.is_a?(Engine::Game::G18OE::Step::BuyTrain)

      s.pass! unless s.is_a?(Engine::Game::G18OE::Step::FormNational) || s.is_a?(Engine::Step::Bankrupt)
    end
  end

  def legal
    Oe::LegalActions.new(game, limit: 12, rng: Random.new(1)).call
  end

  def strategy_choice
    Oe::StrategyPlayer.new(game, rng: Random.new(1)).choose(legal)
  end

  def bot_choice
    Oe::Bot.new(game, rng: Random.new(1)).choose(player_id: alice.id)
  end

  def accepted?(action)
    game.process_action(action)
    game.exception.nil?
  end

  context "when the president can pay the difference" do
    before do
      lnwr.set_cash(80, game.bank)
      alice.set_cash(500, game.bank)
      operate!(lnwr)
    end

    it "buys the cheapest train with the president's help and the engine accepts it" do
      [strategy_choice, bot_choice].each do |choice|
        expect(choice).to be_a(Engine::Action::BuyTrain)
        expect(choice.price).to eq(game.depot.min_depot_price)
      end
      expect(accepted?(strategy_choice)).to be(true)
      expect(lnwr.trains.size).to eq(1)
    end
  end

  context "when treasury and president cannot pay (conversion into a national)" do
    before do
      lnwr.set_cash(10, game.bank)
      alice.set_cash(50, game.bank)
      operate!(lnwr)
    end

    it "is offered the conversion and picks a move the engine accepts, never a share sale" do
      types = legal.map(&:type).uniq
      expect(types).to include("choose")
      expect(types).not_to include("sell_shares")

      choice = strategy_choice
      expect(choice).to be_a(Engine::Action::Choose)
      expect(choice.choice).to eq(game.forced_national_choice)
      expect(bot_choice).to be_a(Engine::Action::Choose)
      expect(accepted?(choice)).to be(true)
      expect(lnwr.type).to eq(:national)
      expect(game.finished).to be(false)
    end
  end
end
