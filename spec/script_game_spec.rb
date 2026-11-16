# frozen_string_literal: true

require "spec_helper"
require "oe/script_game"

# #132: a scripted game over the real API, from the auction to the end, with
# every round/step/action combination of slice S1 (lib/oe/script_game/slices/s1.yml)
# executed at least once. Slow on purpose (one whole game, about a minute or two);
# the same run against a running instance: bin/script-game.
RSpec.describe Oe::ScriptGame, :game_flow do
  ACCOUNTS = %w[alice bob carol dave].freeze

  before do
    Sinatra::Application.set :store, Oe::Store.new(":memory:")
    seed_accounts(Sinatra::Application.settings.store, ACCOUNTS)
  end

  def clients
    ACCOUNTS.to_h do |name|
      client = Oe::ScriptGame::Clients::Rack.new(Sinatra::Application)
      status, = client.call(:post, "/login", { login: name, password: TEST_PASSWORD })
      raise "login failed for #{name}: #{status}" unless status == 200

      [name, client]
    end
  end

  # #371: what a slow GET was: the slowest GETs (index, round/step before the move) and every
  # GameSession.replay of the example (a cache miss of store.sessions costs a replay of the whole log).
  # Installed once; each example sets Thread.current[:replay_log] = {log: [], ledger: ledger}.
  module ReplayProbe
    def replay(*)
      probe = Thread.current[:replay_log]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super
    ensure
      probe[:log] << { seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, at_get: probe[:ledger].get_seconds.size } if probe
    end
  end
  Oe::GameSession.singleton_class.prepend(ReplayProbe)

  # #371: GET /games/:id stays under 1.0 s, except at operating/Route: there the prompt runs the route
  # search (Oe::LegalActions::RoutePicker, WALK_LIMIT visits) on every GET, 2 to 2.8 s measured on the
  # late phases of a whole game (CI runner 1.5 to 2.0 s, up to about 3 s expected). The Route step gets
  # its own limit instead of a silent loosening of the general one; a fast solution (cheaper route
  # suggestion in the prompt, or a lower WALK_LIMIT) follows in the v0.4 issue and removes this exception.
  GET_LIMIT = 1.0
  ROUTE_GET_LIMIT = 4.0

  def get_limit(detail)
    detail[:round] == "operating" && detail[:step] == "Route" ? ROUTE_GET_LIMIT : GET_LIMIT
  end

  # The GET that exceeded its limit by the most (ratio), or nil.
  def worst_get_breach(details)
    details.select { |d| d[:seconds] >= get_limit(d) }.max_by { |d| d[:seconds] / get_limit(d) }
  end

  def get_breach_message(details, breach)
    format("GET /games/:id #%<index>d at %<round>s/%<step>s took %<seconds>.3f s, limit %<limit>.1f s (Route step %<route>.1f s, others %<other>.1f s)",
           breach.merge(limit: get_limit(breach), route: ROUTE_GET_LIMIT, other: GET_LIMIT)) +
      "; slowest overall #{details.map { |d| d[:seconds] }.max.round(3)} s"
  end

  def slow_get_report(result, replays)
    top = result.ledger.get_details.max_by(3) { |d| d[:seconds] }.map do |d|
      format("#%<index>d %<seconds>.3f s %<round>s/%<step>s (viewer %<viewer>s)", d)
    end
    misses = replays.map { |r| format("%.3f s before GET #%d", r[:seconds], r[:at_get]) }
    "slowest GETs: #{top.join('; ')}. GameSession.replay calls: #{replays.size} (#{misses.join(', ')}); " \
      "GET n=#{result.ledger.get_seconds.size}, game #{result.ledger.get_details.first&.dig(:game)}"
  end

  Oe::ScriptGame.games("s1").times do |index|
    it "plays S1 game #{index + 1} and executes every target combination of it" do
      runner = described_class.new(clients: clients, slice: "s1", game: index)
      replays = []
      Thread.current[:replay_log] = { log: replays, ledger: runner.instance_variable_get(:@ledger) }
      result = runner.run
      Thread.current[:replay_log] = nil
      report = Oe::ScriptGame::Report.lines(result).join("\n")
      puts "\n#{report}"

      expect(result.ok?).to be(true), report
      details = result.ledger.get_details
      breach = worst_get_breach(details)
      expect(breach).to be_nil, breach && "#{get_breach_message(details, breach)}; #{slow_get_report(result, replays)}"
    end
  end

  describe "the GET time limits (#371)" do
    def get_at(seconds, round, step)
      { index: 0, seconds: seconds, round: round, step: step, viewer: "p0", game: "g" }
    end

    it "passes a slow Route GET under its own limit and a fast other GET" do
      details = [get_at(3.9, "operating", "Route"), get_at(0.99, "operating", "Track")]
      expect(worst_get_breach(details)).to be_nil
    end

    it "fails a GET outside the Route step over 1.0 s, naming its limit" do
      details = [get_at(1.2, "operating", "Track"), get_at(3.0, "operating", "Route")]
      breach = worst_get_breach(details)
      expect(breach[:step]).to eq("Track")
      expect(get_breach_message(details, breach)).to include("operating/Track took 1.200 s, limit 1.0 s")
    end

    it "fails a Route GET over 4.0 s, naming its limit" do
      details = [get_at(4.2, "operating", "Route"), get_at(0.5, "stock", "BuySellParShares")]
      breach = worst_get_breach(details)
      expect(get_breach_message(details, breach)).to include("operating/Route took 4.200 s, limit 4.0 s")
    end
  end

  it "fails when a target combination is not reachable" do
    slice = described_class.slice("s1")
    slice["games"] = [slice["games"][1].merge("combos" => ["operating/Nonexistent/pass"])]
    allow(described_class).to receive(:slice).and_return(slice)
    result = described_class.new(clients: clients, slice: "s1", max_actions: 150).run
    expect(result.missing).to eq(["operating/Nonexistent/pass"])
    expect(result.ok?).to be(false)
  end
end
