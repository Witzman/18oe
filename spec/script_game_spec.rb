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
      expect(result.ledger.get_seconds.max).to be < 1.0, "slowest GET /games/:id took #{result.ledger.get_seconds.max.round(3)} s; #{slow_get_report(result, replays)}"
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
