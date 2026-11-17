# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "oe/legal_actions"
require "oe/strategy_player"
require "json"
require_relative "../engine/g_18_oe/helpers"
require_relative "../support/view_checks"

# #123: the numbers of the operating steps in `prompt.context`, tile supply,
# phase limits and the train schedule, each checked against the engine method
# it comes from (and against what the engine does when the action is played).
# The checks live in spec/support/view_checks.rb; this group runs them over a
# seed game (full stage), the group below over states built by code (fast, #438).
RSpec.describe "Oe::View operating context (#123)", :game_flow do
  include OeViewChecks

  G = Engine::Game::G18OE

  # One strategy game; yields [game, view] before every action, with the action
  # the strategist is about to play.
  def play(seed: 1, max: STRATEGY_CAP) # #335: capped like the other view specs
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
    @compared = 0
    play do |game, view, action|
      ctx = view[:prompt][:context]
      step = game.round.active_step
      entity = step.current_entity
      label = "action #{game.raw_actions.size} #{step.class.name.split('::').last} #{entity.id}"
      @views << [view, game.depot.upcoming.size, game.tiles.size, game.phase.name, game.phase.current[:train_limit]]
      check(:shape, label) { check_shape(ctx) }
      check(:acting, label) { check_acting(view, entity) }
      check(:track, label) { check_track(ctx[:track], view, step, entity, game) } if ctx[:track]
      check(:token, label) { check_token(ctx[:token], step, entity, game) } if ctx[:token]
      check(:train, label) { check_train(ctx[:train], step, entity, game) } if ctx[:train]
      next unless ctx[:dividend] && action.is_a?(Engine::Action::Dividend)

      before = { round: game.round, cash: entity.cash, holders: (game.players + game.corporations).to_h { |h| [h.id, h.cash] } }
      opt = ctx[:dividend][:options].find { |o| o[:kind] == action.kind }
      check(:dividend, label) { expect(opt).not_to be_nil }
      check(:dividend, label) { check_routes(ctx[:dividend], game) }
      game.process_action(action)
      @game_for_check = game
      @fractional = true if opt[:per_share].to_f != opt[:per_share].to_f.floor
      check(:dividend, label) { check_dividend(opt, entity, before) }
      :processed
    end
  end

  it "saw a fractional dividend rate per share and checked its rounded payouts (#294)" do
    expect(@fractional).to be(true)
  end

  %i[track token dividend train shape acting].each do |family|
    it "has verified #{family} against the engine at every state it appears in" do
      expect(@counts[family]).to be > 0
      expect(@errors[family].first(3)).to eq([])
    end
  end

  it "marks actions issued for someone other than the active entity as not primary" do
    game = G::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    list = [{ "type" => "pass", "entity" => "p0", "entity_type" => "player" },
            { "type" => "convert", "entity" => "LNWR", "entity_type" => "corporation" }]
    acting = Oe::View.acting_as(game, game.round.active_step, list)
    expect(acting).to eq([{ entity: "p0", kind: "player", primary: true, types: ["pass"] },
                          { entity: "LNWR", kind: "corporation", primary: false, types: ["convert"] }])
  end

  it "compared the track panel with the second enumeration on states with several hexes (#340)" do
    expect(@compared).to be > 0
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

# #438: the same checks over states built by code (scenario building blocks of spec/engine/g_18_oe/helpers.rb),
# no seed game: fast stage. Each scenario is one state a seed game reached only late or by chance; a view
# change that breaks one shows before the merge, not in the full stage.
RSpec.describe "Oe::View operating context in states built by code (#438)" do
  include G18OESpecHelpers
  include OeViewChecks

  before do
    @enumerated = 0
    @compared = 0
  end

  # Renders the view for the player to act and checks every context family it shows against the engine.
  # Counts the families checked in `seen`; returns the view.
  def check_view!(game, seen = Hash.new(0))
    step = game.round.active_step
    entity = step.current_entity
    view = Oe::View.render(game, viewer: game.active_players.first&.id, log: nil)
    ctx = view[:prompt][:context]
    check_shape(ctx)
    check_acting(view, entity)
    if ctx[:track]
      check_track(ctx[:track], view, step, entity, game)
      seen[:track] += 1
    end
    { token: :check_token, train: :check_train }.each do |family, check|
      next unless ctx[family]

      send(check, ctx[family], step, entity, game)
      seen[family] += 1
    end
    if ctx[:dividend]
      check_routes(ctx[:dividend], game)
      seen[:dividend] += 1
    end
    view
  end

  # Plays `corp`'s operating turn: checks the view before every action, runs the RoutePicker's routes (what
  # the bots and the UI take), pays out and checks the payout against what the view announced, passes
  # everything else. Returns the families checked.
  def operate!(game, corp)
    seen = Hash.new(0)
    40.times do
      break unless game.round.operating? && game.round.active_step&.current_entity == corp

      view = check_view!(game, seen)
      case game.round.active_step
      when Engine::Step::Route
        act!(game, Engine::Action::RunRoutes.new(corp, routes: Oe::LegalActions::RoutePicker.new(game, corp).call))
      when Engine::Step::Dividend then pay_out!(game, corp, view)
      else act!(game, Engine::Action::Pass.new(corp))
      end
    end
    seen
  end

  def pay_out!(game, corp, view)
    opt = view[:prompt][:context][:dividend][:options].find { |o| o[:kind] == "payout" }
    before = { round: game.round, cash: corp.cash, holders: (game.players + game.corporations).to_h { |h| [h.id, h.cash] } }
    act!(game, Engine::Action::Dividend.new(corp, kind: "payout"))
    @game_for_check = game
    check_dividend(opt, corp, before)
  end

  it "checks a regional's whole operating turn, its run crossing the sea from Valencia (#123, #302, #360)" do
    game = new_game
    corp = operating_regional!(game, "LNWR", game.players[0], trains: ["5"])
    lay_tile!(game, "AA20", "5", rotation: 4)
    lay_tile!(game, "AB27", "5", rotation: 1)
    place_token!(game, "AA20", corp)
    operating_round_for!(game, 1, setup: true)

    seen = operate!(game, corp)

    expect(seen.keys).to include(:track, :dividend, :train)
    expect(corp.operating_history.values.last.revenue).to be_positive
  end

  # #426: Minor E's extra tile point (§15.5) keeps the Track step open with no regular point left; the panel
  # priced the hexes at the regular point, more than was left.
  it "prices the hexes at the extra point of Minor E when no regular point is left (#426)" do
    game = new_game
    major = start_major!(game, "GWR", game.players[0])
    game.add_minor_charter!(game.corporation_by_id("E"), major)
    step = operating_round_for!(game, 1).active_step
    step.instance_variable_set(:@points_used, game.tile_point_budget(major))

    view = check_view!(game)

    expect(view[:prompt][:context][:track][:points][:left]).to eq(0)
    expect(view[:prompt][:context][:track][:hexes]).not_to be_empty
  end
end
