# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "oe/strategy_player"
require "json"

# One full 4-player strategy game, played once; views are rendered at the first
# state of every round type seen, every 500 actions, and at the end.
RSpec.describe Oe::View do
  PLAIN = [Hash, Array, String, Symbol, Integer, Float, TrueClass, FalseClass, NilClass].freeze

  def plain?(value)
    return false unless PLAIN.any? { |k| value.is_a?(k) }

    case value
    when Hash then value.all? { |k, v| (k.is_a?(String) || k.is_a?(Symbol)) && plain?(v) }
    when Array then value.all? { |v| plain?(v) }
    else true
    end
  end

  def stringify(value)
    JSON.parse(JSON.generate(value))
  end

  def total_money(view)
    view[:players].sum { |p| p[:cash] } + view[:corporations].sum { |c| c[:cash] } + view[:bank][:cash]
  end

  before(:all) do
    @game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    rng = Random.new(1)
    strategist = Oe::StrategyPlayer.new(@game, rng: rng)
    @samples = [] # [label, view, spectator_view]
    seen = {}
    count = 0
    snapshot = lambda do |label|
      viewer = @game.finished ? nil : @game.active_players.first&.id
      @samples << [label, Oe::View.render(@game, viewer: viewer), Oe::View.render(@game, viewer: nil)]
    end
    until @game.finished || count > 20_000
      type = Oe::View.round_type(@game.round)
      snapshot.call("first #{type}") unless seen[type]
      seen[type] = true
      snapshot.call("action #{count}") if (count % 500).zero?
      actions = Oe::LegalActions.new(@game, limit: 8, rng: rng).call
      @game.process_action(strategist.choose(actions) || actions.sample(random: rng))
      count += 1
    end
    snapshot.call("end")
    @round_types = seen.keys
  end

  it "covers the main round types and the end of the game" do
    expect(@round_types).to include("auction", "concession", "stock", "operating")
    expect(@game.finished).to be(true)
  end

  it "has the documented top-level shape in every state" do
    @samples.each do |label, view, _|
      expect(view.keys).to eq(%i[meta players corporations market depot tiles bank auction concession zones map log prompt]), label
      expect(view[:meta].keys).to include(:seq, :finished, :round, :phase, :current, :active_players, :standings), label
      expect(view[:players].size).to eq(4), label
    end
  end

  it "has an auction section exactly while an auction round runs (#120)" do
    @samples.each do |label, view, _|
      if view[:meta][:round][:type] == "auction"
        expect(view[:auction][:cards]).not_to be_empty, label
        expect(view[:auction][:cards].size).to be <= 32, label
      else
        expect(view[:auction]).to be_nil, label
      end
    end
  end

  it "contains only plain data (no engine objects) and survives a JSON round trip" do
    @samples.each do |label, view, spectator|
      [view, spectator].each do |v|
        expect(plain?(v)).to be(true), label
        expect(stringify(v)).to eq(stringify(stringify(v))), label
      end
    end
  end

  it "is deterministic: rendering twice gives the same result" do
    label, view, = @samples[2]
    viewer = view[:prompt][:viewer_to_act] ? view[:meta][:active_players].first : nil
    expect(stringify(Oe::View.render(@game, viewer: viewer))).to eq(stringify(Oe::View.render(@game, viewer: viewer))), label
  end

  it "keeps the money in the game constant (players + corporations + bank)" do
    totals = @samples.map { |_, view, _| total_money(view) }.uniq
    expect(totals.size).to eq(1), "money totals differ: #{totals.first(5)}"
  end

  it "holds 100 percent of every ipoed corporation across its holders" do
    @samples.each do |label, view, _|
      view[:corporations].select { |c| c[:ipoed] && !c[:closed] }.each do |c|
        expect(c[:shares].sum { |s| s[:percent] }).to eq(100), "#{label}: #{c[:id]} #{c[:shares]}"
      end
    end
  end

  it "offers legal actions only to the viewer who is to act" do
    acting = @samples.reject { |_, v, _| v[:meta][:finished] }
    expect(acting).not_to be_empty
    acting.each do |label, view, spectator|
      expect(view[:prompt][:viewer_to_act]).to be(true), label
      expect(view[:prompt][:actions]).not_to be_empty, label
      expect(spectator[:prompt][:viewer_to_act]).to be(false), label
      expect(spectator[:prompt][:actions]).to be_empty, label
      expect(spectator[:prompt][:types]).to eq(view[:prompt][:types]), label
    end
  end

  it "reports the final standing when the game is finished" do
    _, view, = @samples.last
    expect(view[:meta][:finished]).to be(true)
    expect(view[:meta][:winner]).to eq(view[:meta][:standings].first[:player])
    expect(view[:meta][:standings].map { |s| s[:value] }).to eq(view[:meta][:standings].map { |s| s[:value] }.sort.reverse)
    expect(view[:prompt][:actions]).to be_empty
  end

  it "lists only changed hexes on the map, with tile, rotation and tokens" do
    _, view, = @samples.last
    expect(view[:map]).not_to be_empty
    expect(view[:map].map { |h| h[:hex] }).to eq(view[:map].map { |h| h[:hex] }.sort)
    expect(view[:map].all? { |h| h[:tile][:name] && h[:tile][:rotation] }).to be(true)
    expect(view[:map].any? { |h| h[:tokens].any? }).to be(true)
  end

  it "uses the engine's log, trimmed to the requested length" do
    expect(Oe::View.render(@game, log: 5, actions: false)[:log].size).to eq(5)
    expect(Oe::View.render(@game, log: nil, actions: false)[:log]).to eq([])
  end

  it "renders fast and small enough" do
    _, view, = @samples.last
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Oe::View.render(@game, viewer: nil)
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(took).to be < 1.0
    expect(JSON.generate(view).bytesize).to be < 1_000_000
  end
end
