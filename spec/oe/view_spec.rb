# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require_relative "../support/check_game"
require "json"

# One game played once: the bots-only test game of spec/support/check_game.rb (#602: 3 bots, seed 1; the strategy
# game seed 1 / 4 players before it no longer reaches its end). Views are rendered at the first state of every round
# type and of every phase seen, every 500 actions, and at the end. Capped at GAME_CAP moves; to its end in the full
# stage (OE_FULL_GAME=1).
RSpec.describe Oe::View, :game_flow do
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
    @samples = [] # [label, view, spectator_view, injected]
    seen = {}
    count = 0
    snapshot = lambda do |game, label|
      viewer = game.finished ? nil : game.active_players.first&.id
      # the phase-8 event adds REMAINDER_CASH to the bank (rule, game.rb event_remainder_cash_added!)
      injected = game.instance_variable_get(:@remainder_cash_added) ? game.class::REMAINDER_CASH : 0
      @samples << [label, Oe::View.render(game, viewer: viewer), Oe::View.render(game, viewer: nil), injected]
    end
    @game, = OeCheckGame.play(max: GAME_CAP) do |game|
      type = Oe::View.round_type(game.round)
      snapshot.call(game, "first #{type}") unless seen[type]
      seen[type] = true
      phase = "phase #{game.phase.name}"
      snapshot.call(game, "first #{phase}") unless seen[phase]
      seen[phase] = true
      snapshot.call(game, "action #{count}") if (count % 500).zero?
      count += 1
    end
    snapshot.call(@game, "end")
    @round_types = seen.keys.reject { |k| k.start_with?("phase ") }
  end

  it "covers the main round types and the end of the game" do
    expect(@round_types).to include("auction", "concession", "stock", "operating")
    expect(@game.finished).to be(true) if FULL_GAME
  end

  # #602: the end checks below need the late game; the test game must reach it (full stage).
  it "reaches phase 8 with the remainder cash and nationals in the whole game", if: FULL_GAME do
    expect(@samples.any? { |_, _, _, injected| injected.positive? }).to be(true), "no sample after the phase-8 remainder cash"
    nationals = @samples.flat_map { |_, view, _| view[:corporations] }.select { |c| c[:type] == "national" && c[:ipoed] }
    expect(nationals).not_to be_empty, "no ipoed national in any sample"
  end

  it "has the documented top-level shape in every state" do
    @samples.each do |label, view, _|
      expect(view.keys).to eq(%i[meta players corporations market depot tiles bank auction concession companies zones map log prompt]), label
      expect(view[:meta].keys).to include(:seq, :finished, :round, :phase, :current, :active_players, :standings), label
      expect(view[:players].size).to eq(OeCheckGame::PLAYERS), label
    end
  end

  it "has an auction section exactly while an auction round runs (#120)" do
    @samples.each do |label, view, _|
      if view[:meta][:round][:type] == "auction"
        expect(view[:auction][:cards]).not_to be_empty, label
        expect(view[:auction][:cards].size).to be <= 33, label
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
    totals = @samples.map { |_, view, _, injected| total_money(view) - injected }.uniq
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

  # "reports the final standing when the game is finished" needs a whole game: bot_runner_spec (:full_game, #314).

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
