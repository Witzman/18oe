# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../support/check_game"
require "oe/view"

# The test game of the long view specs (#602): a few moves only.
RSpec.describe OeCheckGame, :game_flow do
  it "plays the bots-only game with the hook before every move and returns the game" do
    seen = []
    game, incidents = described_class.play(max: 20) { |g| seen << g.raw_actions.size }
    expect(game.players.map(&:id)).to eq(%w[p0 p1 p2])
    expect(game.raw_actions.size).to eq(20)
    expect(seen).to eq((0...20).to_a)
    expect(incidents).to eq([])
  end

  it "plays the same moves as the runner without a hook" do
    store = Oe::Store.new(":memory:")
    seats = Array.new(3) { |i| { "seat" => i, "kind" => "bot", "name" => "S#{i}" } }
    id = Oe::GameSession.create(store, seats: seats, seed: 1).id
    Oe::BotRunner.new(store).drain(id, max: 40)
    plain = store.action_payloads(id).map { |a| a.reject { |k, _| k == "created_at" } }

    game, = described_class.play(max: 40) { |g| Oe::View.render(g, viewer: g.active_players.first&.id) }
    expect(game.raw_actions.map { |a| a.reject { |k, _| k == "created_at" } }).to eq(plain)
  end
end
