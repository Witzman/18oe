# frozen_string_literal: true

require "spec_helper"
require "oe/script_game"

# #132: a scripted game over the real API, from the auction to the end, with
# every round/step/action combination of slice S1 (lib/oe/script_game/slices/s1.yml)
# executed at least once. Slow on purpose (one whole game, about a minute or two);
# the same run against a running instance: bin/script-game.
RSpec.describe Oe::ScriptGame do
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

  Oe::ScriptGame.games("s1").times do |index|
    it "plays S1 game #{index + 1} and executes every target combination of it" do
      result = described_class.new(clients: clients, slice: "s1", game: index).run
      report = Oe::ScriptGame::Report.lines(result).join("\n")
      puts "\n#{report}"

      expect(result.ok?).to be(true), report
      expect(result.ledger.get_seconds.max).to be < 1.0, "slowest GET /games/:id took #{result.ledger.get_seconds.max.round(3)} s"
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
