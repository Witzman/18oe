# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/history"
require "oe/legal_actions"
require "oe/strategy_player"
require "json"

# #115: the time series, checked against the engine as it plays.
RSpec.describe Oe::History do
  def json(value) = JSON.parse(JSON.generate(value))

  # Plays a strategy game, recording in step and keeping the true share price
  # of every corporation after every action for comparison.
  def play(steps: 2600)
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    history = described_class.new(game)
    strategist = Oe::StrategyPlayer.new(game, rng: Random.new(1))
    rng = Random.new(1)
    truth = {}
    steps.times do
      break if game.finished

      acts = Oe::LegalActions.new(game, limit: 12, rng: rng).call
      break if acts.empty?

      game.process_action(strategist.choose(acts))
      history.record
      truth[game.current_action_id] = game.corporations.to_h { |c| [c.id, c.closed? ? nil : c.share_price&.price] }
    end
    [game, history, truth]
  end

  before(:all) { @game, @history, @truth = play }

  let(:game) { @game }
  let(:history) { @history }
  let(:truth) { @truth }
  let(:data) { json(history.to_h) }

  it "reproduces the share price of every corporation at every action" do
    points = data["share_prices"]
    expect(points).not_to be_empty
    truth.each do |action, prices|
      prices.each do |corp, price|
        last = (points[corp] || []).select { |pt| pt["action"] <= action }.last
        expect(last ? last["price"] : nil).to eq(price), "#{corp} at action #{action}"
      end
    end
  end

  it "records a point only when the price changed, in log order" do
    data["share_prices"].each_value do |pts|
      expect(pts.map { |pt| pt["action"] }).to eq(pts.map { |pt| pt["action"] }.sort)
      expect(pts.each_cons(2).all? { |a, b| a["price"] != b["price"] }).to be(true)
      expect(pts).to all(include("turn", "round", "number"))
    end
  end

  it "takes player values from the engine's own record, ending at the final result" do
    values = data["player_values"]
    expect(values.keys).to eq(game.players.map(&:id))
    game.players.each do |p|
      expect(values[p.id].size).to eq(p.history.size)
      expect(values[p.id]).to all(include("round", "turn", "number", "value"))
    end
    next unless game.finished

    game.players.each { |p| expect(values[p.id].last["value"]).to eq(game.player_value(p)) }
  end

  it "reports the revenue and payout of each operating round from the engine's operating history" do
    revenue = data["revenue"]
    expect(revenue).not_to be_empty
    game.corporations.each do |corp|
      rows = revenue[corp.id]
      expect(rows).to be_nil if corp.operating_history.empty?
      next unless rows

      expect(rows.map { |r| [r["turn"], r["number"]] }).to eq(corp.operating_history.keys)
      expect(rows.map { |r| r["revenue"] }).to eq(corp.operating_history.values.map(&:revenue))
      expect(rows.map { |r| r["dividend"] }).to all(satisfy { |d| %w[payout half withhold].include?(d) })
    end
  end

  it "gives the same result when replayed from the raw action log" do
    replayed = described_class.replay(%w[p0 p1 p2 p3], id: 1, seed: 1, payloads: game.raw_actions)
    expect(json(replayed.to_h)).to eq(data)
  end
end
