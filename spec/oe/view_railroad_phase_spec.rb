# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "oe/legal_actions"
require "oe/strategy_player"
require "json"

# #121: concession sequence, railroad phase, regional states and track-rights
# zones in the view, checked against the engine over a strategy game and a
# random game.
RSpec.describe "Oe::View railroad phase (#121)" do
  REGIONAL_STATES = %w[unparred parred floated converted removed closed].freeze

  def play(game, rng, strategist, max: 20_000)
    count = 0
    until game.finished || count > max
      yield count
      acts = Oe::LegalActions.new(game, limit: 8, rng: rng).call
      break if acts.empty?

      game.process_action(strategist ? (strategist.choose(acts) || acts.sample(random: rng)) : acts.sample(random: rng))
      count += 1
    end
  end

  def json(view) = JSON.parse(JSON.generate(view))

  def check_counts(game, view, label)
    rr = view[:meta][:railroads]
    list = rr[:regional_states]
    states = list.map { |r| r[:state] }
    expect(list.size).to eq(24), label
    expect(states - REGIONAL_STATES).to be_empty, label
    expect(rr[:regionals]).to include(total: 24, max_floated: 18, max_removed: 6)
    tally = states.tally
    (REGIONAL_STATES - %w[floated]).each { |s| expect(rr[:regionals][s.to_sym]).to eq(tally.fetch(s, 0)), "#{label} #{s}" }
    expect(rr[:regionals][:floated]).to eq(tally.fetch("floated", 0) + tally.fetch("converted", 0)), label
    expect(rr[:regionals][:removed]).to be <= 6
    # against the engine objects, by id (closed regionals are no longer in game.corporations)
    list.each do |r|
      corp = game.corporation_by_id(r[:id])
      case r[:state]
      when "unparred" then expect([corp.ipoed, corp.closed?]).to eq([false, false]), label
      when "parred" then expect([corp.ipoed, corp.floated?, corp.type]).to eq([true, false, :regional]), label
      when "floated" then expect([corp.floated?, corp.type]).to eq([true, :regional]), label
      when "converted" then expect([corp.floated?, corp.type]).to eq([true, :major]), label
      when "removed" then expect([corp.closed?, corp.par_price]).to eq([true, nil]), label
      end
      expect(view[:corporations].find { |v| v[:id] == r[:id] }&.fetch(:regional_state)).to eq(r[:state]) unless corp.closed?
    end
    expect(game.corporations.count { |c| c.type == :regional && !c.closed? }).to eq(rr[:regionals][:unparred] + rr[:regionals][:parred] + tally.fetch("floated", 0)), label
    expect(rr[:minors]).to eq(floated: game.minor_floated_regions.size, total: 12), label
  end

  def phase_sequence(game, rng, strategist)
    seq = []
    play(game, rng, strategist) do |n|
      view = Oe::View.render(game, actions: false, log: nil)
      check_counts(game, view, "action #{n}") if (n % 40).zero?
      phase = view[:meta][:rr_phase]
      seq << phase if seq.last != phase
      expect(%w[auction concession regional_minor major consolidation]).to include(phase)
      expect(view[:meta][:rr_phase] == "major").to eq(game.major_phase? && view[:meta][:round][:type] != "consolidation") if view[:meta][:round][:type] != "auction"
    end
    seq
  end

  it "starts in the auction with everything unparred and all zone chits free" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    view = Oe::View.render(game, actions: false)
    expect(view[:meta][:rr_phase]).to eq("auction")
    check_counts(game, view, "start")
    expect(view[:meta][:railroads][:regionals]).to include(unparred: 24, parred: 0, floated: 0, removed: 0)
    expect(view[:concession]).to be_nil
    expect(view[:zones].map { |z| z[:id] }).to eq(%w[UK PHS FR AH IT SP SC RU])
    expect(view[:zones].map { |z| z[:price] }).to eq([40, 40, 20, 20, 10, 10, 10, 10])
    expect(view[:zones]).to all(include(free: true, chits_left: 2, taken_by: []))
    expect(view[:zones].select { |z| z[:discount] > 0 }.map { |z| z[:id] }).to eq(%w[IT SP SC RU])
  end

  it "passes plain JSON" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    v = Oe::View.render(game, actions: false)
    expect(json(v)["concession"]).to be_nil
    expect(json(v)["zones"].size).to eq(8)
  end

  it "lists the ten concessions with owner and status while the concession round runs and afterwards" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    rng = Random.new(1)
    strategist = Oe::StrategyPlayer.new(game, rng: rng)
    states = []
    play(game, rng, strategist, max: 4000) do
      type = Oe::View.round_type(game.round)
      break if type == "stock"

      next unless type == "concession"

      list = Oe::View.render(game, actions: false)[:concession]
      expect(list.map { |c| c[:id] }).to eq((1..10).map { |i| "CON#{i}" })
      expect(list.map { |c| c[:status] }.tally.fetch("current", 0)).to eq(1)
      states << list.map { |c| c[:status] }
      done = list.take_while { |c| c[:status] == "done" }.size
      expect(list.drop(done).first[:status]).to eq("current")
      expect(list.drop(done + 1).map { |c| c[:status] }.uniq - ["open"]).to be_empty
      expect(list.map { |c| c[:owner] }).to all(match(/\Ap[0-3]\z/))
      expect(list.take(done).map { |c| game.company_by_id(c[:id]).closed? }).to all(be(true))
      expect(list.drop(done + 1).map { |c| game.company_by_id(c[:id]).closed? }).to all(be(false))
      expect(Oe::View.render(game, actions: false)[:meta][:rr_phase]).to eq("concession")
    end
    expect(states.size).to be > 10
    expect(states.last.count("done")).to be >= 9

    view = Oe::View.render(game, actions: false)
    expect(view[:concession].map { |c| c[:status] }.uniq).to eq(["done"])
    expect(view[:concession].map { |c| c[:owner] }).to all(match(/\Ap[0-3]\z/))
    expect(view[:meta][:rr_phase]).to eq("regional_minor")
  end

  it "switches phase exactly once per transition and keeps the counts in step with the engine (strategy game)" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    rng = Random.new(1)
    seq = phase_sequence(game, rng, Oe::StrategyPlayer.new(game, rng: rng))
    expect(seq.first(3)).to eq(%w[auction concession regional_minor])
    expect(seq.count("auction")).to eq(1)
    expect(seq.count("concession")).to eq(1)
    expect(seq.count("regional_minor")).to eq(1)
  end

  it "keeps the same invariants in a random game" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2], id: 2, seed: 5)
    seq = phase_sequence(game, Random.new(5), nil)
    expect(seq.first).to eq("auction")
    expect(seq.count("auction")).to eq(1)
    expect(seq.count("concession")).to be <= 1
    expect(seq.count("regional_minor")).to be <= 1
  end

  it "shows a taken zone chit and its price once a minor floated" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    rng = Random.new(1)
    strategist = Oe::StrategyPlayer.new(game, rng: rng)
    play(game, rng, strategist, max: 6000) { break if game.minor_floated_regions.any? }
    expect(game.minor_floated_regions).not_to be_empty
    view = Oe::View.render(game, actions: false)
    game.minor_floated_regions.each do |minor, zone|
      z = view[:zones].find { |x| x[:id] == zone }
      expect(z[:taken_by]).to include(minor)
      expect(z[:chits_left]).to eq(game.minor_available_regions[zone] || 0)
      expect(z[:free]).to eq(z[:chits_left].positive?)
    end
  end
end
