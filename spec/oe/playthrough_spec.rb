# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/playthrough"
require "tmpdir"

# Small, permanent run of the random-playthrough harness (#31). The full
# collecting run is `bin/playthrough --players 3-7 --seeds 1-10`.
RSpec.describe Oe::Playthrough do
  let(:statuses) { %i[finished crash rejected dead_end limit] }

  [1, 2, 3].each do |seed|
    it "is deterministic for seed #{seed} and stops at the action limit" do
      first = described_class.run(players: 4, seed: seed, max_actions: 250)
      second = described_class.run(players: 4, seed: seed, max_actions: 250)

      expect(statuses).to include(first.status)
      expect(first.status).to eq(:limit)
      expect(first.actions).to eq(250)
      expect(first.log).to eq(second.log)
    end
  end

  it "writes a replayable log" do
    result = described_class.run(players: 3, seed: 1, max_actions: 40)
    Dir.mktmpdir do |dir|
      path = described_class.write_log(result, dir)
      data = JSON.parse(File.read(path))
      game = Engine::Game::G18OE::Game.new(%w[A B C], id: 1, seed: 1, actions: data["actions_log"])

      expect(game.raw_actions.size).to eq(40)
      expect(game.exception).to be_nil
    end
  end

  it "reports a dead end instead of raising" do
    result = described_class.run(players: 4, seed: 1, max_actions: 5000)

    expect(%i[dead_end rejected crash finished]).to include(result.status)
    expect(result.detail).not_to be_nil unless result.status == :finished
  end
end
