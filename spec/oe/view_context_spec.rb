# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "oe/legal_actions"
require "oe/strategy_player"
require "json"

# #123: the numbers of the operating steps in `prompt.context`, tile supply,
# phase limits and the train schedule, each checked against the engine method
# it comes from (and against what the engine does when the action is played).
RSpec.describe "Oe::View operating context (#123)" do
  G = Engine::Game::G18OE

  # One strategy game; yields [game, view] before every action, with the action
  # the strategist is about to play.
  def play(seed: 1, max: 6000)
    game = G::Game.new(%w[p0 p1 p2 p3], id: seed, seed: seed)
    rng = Random.new(seed)
    strategist = Oe::StrategyPlayer.new(game, rng: rng)
    count = 0
    until game.finished || count > max
      viewer = game.active_players.first&.id
      view = Oe::View.render(game, viewer: viewer, log: nil)
      acts = Oe::LegalActions.new(game, limit: 8, rng: rng).call
      break if acts.empty?

      action = strategist.choose(acts) || acts.sample(random: rng)
      game.process_action(action) unless yield(game, view, action) == :processed
      count += 1
    end
  end

  # Runs the expectations right away against the live game (it moves on after the
  # action); failures are kept per family and reported by the examples.
  def check(family, label)
    @counts[family] += 1
    yield
  rescue RSpec::Expectations::ExpectationNotMetError, StandardError => e
    @errors[family] << "#{label}: #{e.class} #{e.message.lines.first(3).join(' ')}"
  end

  before(:all) do
    @counts = Hash.new(0)
    @errors = Hash.new { |h, k| h[k] = [] }
    @views = []
    @enumerated = 0
    play do |game, view, action|
      ctx = view[:prompt][:context]
      step = game.round.active_step
      entity = step.current_entity
      label = "action #{game.raw_actions.size} #{step.class.name.split('::').last} #{entity.id}"
      @views << [view, game.depot.upcoming.size, game.tiles.size, game.phase.name, game.phase.current[:train_limit]]
      check(:shape, label) { expect(ctx.keys).to eq(%i[track token dividend train]); JSON.generate(ctx) }
      check(:track, label) { check_track(ctx[:track], view, step, entity, game) } if ctx[:track]
      check(:token, label) { check_token(ctx[:token], step, entity, game) } if ctx[:token]
      check(:train, label) { check_train(ctx[:train], step, entity, game) } if ctx[:train]
      next unless ctx[:dividend] && action.is_a?(Engine::Action::Dividend)

      before = { cash: entity.cash }
      opt = ctx[:dividend][:options].find { |o| o[:kind] == action.kind }
      check(:dividend, label) { expect(opt).not_to be_nil }
      game.process_action(action)
      check(:dividend, label) { check_dividend(opt, entity, before) }
      :processed
    end
  end

  def check_track(track, view, step, entity, game)
    expect(track[:points]).to eq(budget: game.tile_point_budget(entity), used: step.points_used, left: step.points_left(entity))
    expect(track[:hexes]).not_to be_nil if view[:prompt][:viewer_to_act]
    (track[:hexes] || []).each do |h|
      hex = game.hex_by_id(h[:hex])
      expect(step.available_hex(entity, hex)).to be_truthy
      expect(h[:cost]).to eq(game.upgrade_cost(hex.tile, hex, entity, entity))
      expect(h[:cost_parts].sum { |p| p[:amount] }).to eq(h[:cost])
      expect(h[:points]).to eq(step.points_for_hex(hex))
      expect(h[:points]).to be <= track[:points][:left]
      expect(h[:tiles].map { |t| t[:name] }.sort).to eq(step.upgradeable_tiles(entity, hex).map { |t| t.name.to_s }.sort)
      h[:tiles].each { |t| expect(t[:rotations]).not_to be_empty }
    end
    return unless track[:hexes] && @enumerated < 15

    @enumerated += 1
    legal = Oe::LegalActions.new(game, limit: nil).call.grep(Engine::Action::LayTile)
    from_view = track[:hexes].flat_map { |h| h[:tiles].flat_map { |t| t[:rotations].map { |r| [h[:hex], t[:name], r] } } }
    expect(from_view.sort).to eq(legal.map { |a| [a.hex.id, a.tile.name.to_s, a.rotation] }.sort)
  end

  def check_token(token, step, entity, game)
    tokens = step.available_tokens(entity)
    expect(token[:tokens_left]).to eq(tokens.size)
    (token[:cities] || []).each do |c|
      expect(c[:price]).to be_a(Integer)
      city = game.city_by_id(c[:id])
      expect(city.hex.id).to eq(c[:hex])
      next unless step.is_a?(G::Step::HomeToken) && tokens.first.corporation.type == :minor

      expect(c[:price]).to eq(game.track_rights_cost(game.region_for_hex(city.hex)))
    end
    return if step.is_a?(G::Step::HomeToken)

    expect(token[:price]).to eq(tokens.first.price)
    expect(token[:kind]).to eq("operating")
  end

  # What the view promised is what the engine did: the treasury grew by `treasury`,
  # the share price is the predicted one.
  def check_dividend(opt, entity, before)
    expect(opt[:price]).to eq(entity.share_price&.price)
    expect(entity.cash - before[:cash]).to eq(opt[:treasury])
  end

  def check_train(train, step, entity, game)
    expect(train[:limit]).to eq(game.train_limit(entity))
    expect(train[:count]).to eq(entity.trains.size)
    expect(train[:must_buy]).to eq(step.must_buy_train?(entity) ? true : false)
    expect(train[:obligation]).to eq(active: game.train_obligation_active?, fulfilled: game.fulfilled_train_obligation?(entity))
    reserved = game.depot.depot_trains.find { |t| t.name == "2+2" && t.from_depot? }
    expect(train[:reserved]&.fetch(:price)).to eq(reserved&.price)
    expect(train[:shortfall]).to eq(train[:must_buy] && train[:cheapest_price] ? [train[:cheapest_price] - entity.cash, 0].max : 0)
    @short = true if train[:shortfall].positive?
  end

  %i[track token dividend train shape].each do |family|
    it "has verified #{family} against the engine at every state it appears in" do
      expect(@counts[family]).to be > 0
      expect(@errors[family].first(3)).to eq([])
    end
  end

  it "saw a president having to chip in for a train" do
    expect(@short).to be(true)
  end

  it "does not touch the game log while pricing tiles" do
    game = G::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    size = game.log.size
    Oe::View.render(game, viewer: "p0")
    expect(game.log.size).to eq(size)
  end

  it "lists train limits per type, the next phase and its trigger, the schedule and the tile supply" do
    @views.each do |view, upcoming, tiles, phase_name, limit|
      phase = view[:meta][:phase]
      expect(phase[:name]).to eq(phase_name)
      expect(phase[:train_limits]).to eq(limit.to_h { |k, v| [k.to_s, v] })
      expect(view[:depot][:schedule].sum { |s| s[:count] }).to eq(upcoming)
      expect(view[:tiles].sum { |t| t[:remaining] }).to eq(tiles)
    end
    first = @views.first.first
    nxt = first[:meta][:phase][:next]
    expect(nxt).to include(name: "3", on: "3")
    expect(nxt[:train_limits]).to include("major" => 4)
    expect(first[:depot][:schedule].find { |s| s[:name] == "3" }[:phase_on]).to eq("3")
  end
end
