# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "oe/legal_actions"
require "oe/strategy_player"
require "json"
require_relative "../engine/g_18_oe/helpers"
require_relative "../support/view_checks"

# #119: the run each train drove, per corporation, in the view. Checked against a
# played game: the train revenues add up, the hexes exist on the board, and the
# paths form a connected sequence (check_last_run, spec/support/view_checks.rb).
RSpec.describe "Oe::View last_run routes (#119)", :game_flow do
  include OeViewChecks

  it "describes every train's run consistently in a played game" do
    game = Engine::Game::G18OE::Game.new(%w[A B C D], id: 1, seed: 1)
    rng = Random.new(1)
    strategist = Oe::StrategyPlayer.new(game, rng: rng)
    seen = 0
    runs = []
    2600.times do |i|
      break if game.finished

      acts = Oe::LegalActions.new(game, limit: 12, rng: rng).call
      break if acts.empty?

      game.process_action(strategist.choose(acts))
      next unless (i % 50).zero?

      view = JSON.parse(JSON.generate(Oe::View.render(game, log: nil, actions: false)))
      view["corporations"].each { |c| runs << c["last_run"] if c["last_run"] && c["last_run"]["routes"].any? }
    end

    expect(runs).not_to be_empty
    runs.each { |run| seen += check_last_run(run, game) }
    expect(seen).to be > 0
  end

  it "has no routes for a corporation that never ran" do
    game = Engine::Game::G18OE::Game.new(%w[A B C D], id: 1, seed: 1)
    view = Oe::View.render(game, log: nil, actions: false)
    expect(view[:corporations].map { |c| c[:last_run] }.compact).to eq([])
  end
end

# #438: the same check over runs built by code (fast stage): the corporation runs the RoutePicker's routes
# (what the bots and the UI take) through the engine's Route and Dividend steps, then the view is read.
RSpec.describe "Oe::View last_run routes in states built by code (#438)" do
  include G18OESpecHelpers
  include OeViewChecks

  let(:game) { new_game }
  let(:corp) { operating_regional!(game, "LNWR", game.players[0], trains: ["5"]) }

  # Passes until the Route step, runs the picked routes, pays out. Returns the corporation's last run in the
  # view, as JSON.
  def run_and_read!
    operating_round_for!(game, 1, setup: true)
    act!(game, Engine::Action::Pass.new(corp)) until game.round.active_step.is_a?(Engine::Step::Route)
    act!(game, Engine::Action::RunRoutes.new(corp, routes: Oe::LegalActions::RoutePicker.new(game, corp).call))
    act!(game, Engine::Action::Dividend.new(corp, kind: "payout"))
    view = JSON.parse(JSON.generate(Oe::View.render(game, log: nil, actions: false)))
    view["corporations"].find { |c| c["id"] == corp.id }["last_run"]
  end

  # #436: the segments skipped the crossing (a chain without track) and so no longer followed the hexes.
  it "follows the hexes with the segments of a run that crosses the sea after track (#436)" do
    corp
    lay_tile!(game, "AA20", "5", rotation: 4)
    lay_tile!(game, "AB27", "5", rotation: 1)
    place_token!(game, "AA20", corp)

    run = run_and_read!

    expect(check_last_run(run, game)).to eq(1)
    expect(run["routes"].first["hexes"]).to include("AB27", "AA20", "AF25") # Palma, Valencia, over the sea to Alger
    expect(run["routes"].first["segments"]).not_to be_empty
  end
end
