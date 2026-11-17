# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/strategy_player"
require "oe/view"

# #64 (§11.6.6): a national takes trains at price 0 with BuyTrain; `exchange` is the rusted train
# it gives back. The enumerator offers every claim, exchange and upgrade, and a pass; the strategy
# claims the highest unclaimed rusted train, then exchanges, never strips its own majors.
RSpec.describe Oe::LegalActions, "national trains (§11.6.6)" do
  include G18OESpecHelpers

  let(:game) { at_phase!(new_game, "4") }
  let(:alice) { game.players[0] }
  let!(:lnwr) { start_major!(game, "LNWR", alice) }
  let!(:plm) { start_major!(game, "PLM", alice) }
  let(:round) { operating_round_for!(game, 1) }

  def card(name)
    game.depot.upcoming.find { |t| t.name == name }
  end

  def unclaimed!(name)
    card(name).tap do |train|
      game.buy_train(plm, train, :free)
      game.rust(train)
    end
  end

  def operate!(corporation)
    round.instance_variable_set(:@entity_index, round.entities.index(corporation))
    round.instance_variable_set(:@current_operator, corporation)
    round.steps.each do |s|
      break if s.is_a?(Engine::Game::G18OE::Step::BuyTrain)

      s.pass! unless s.is_a?(Engine::Game::G18OE::Step::ConvertToNational) || s.is_a?(Engine::Step::Bankrupt)
    end
  end

  def legal
    Oe::LegalActions.new(game).call
  end

  let!(:old) do
    unclaimed!("2+2").tap { |train| game.buy_train(lnwr, train, :free) }
  end

  before do
    game.form_national!(lnwr)
    unclaimed!("3")
    game.buy_train(plm, card("4"), :free)
    operate!(lnwr)
  end

  it "offers a claim, an exchange, an upgrade and a pass, each at price 0" do
    buys = legal.select { |a| a.is_a?(Engine::Action::BuyTrain) }

    expect(buys.map(&:price).uniq).to eq([0])
    expect(buys.map { |a| [a.train.name, a.exchange&.name] }).to contain_exactly(["3", nil], ["3", "2+2"], ["4", "2+2"])
    expect(legal.map(&:type)).to include("pass")
  end

  it "has the offered claim accepted by the engine" do
    action = legal.find { |a| a.is_a?(Engine::Action::BuyTrain) && a.exchange.nil? }
    game.process_action(action)
    expect(game.exception).to be_nil
    expect(lnwr.trains.map(&:name)).to contain_exactly("2+2", "3+3")
  end

  it "lets the strategy claim first and never take a train of its own major" do
    choice = Oe::StrategyPlayer.new(game, rng: Random.new(1)).choose(legal)
    expect(choice).to be_a(Engine::Action::BuyTrain)
    expect([choice.train.name, choice.exchange]).to eq(["3", nil])

    game.process_action(choice)
    expect(plm.trains.map(&:name)).to eq(["4"])
  end

  it "shows no unsupported action in the prompt" do
    expect(Oe::View.render(game, viewer: alice.id)[:prompt][:unsupported]).to be_empty
  end
end
