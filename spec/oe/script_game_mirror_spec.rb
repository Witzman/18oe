# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/script_game"

# #589: the server processes every action with add_auto_actions (game_session.rb), so the auto-passes
# of steps that have nothing to do run on its side; the bot mirror must do the same or it stays in an
# earlier step and diverges from the server.
RSpec.describe "ScriptGame mirror (#589)" do
  it "feeds an accepted action to the mirror with add_auto_actions: true" do
    client = Object.new
    def client.call(*) = [200, { "state" => {} }, 0.0]
    script = Oe::ScriptGame.new(clients: { "a" => client }, slice: "s2")
    mirror = instance_double(Engine::Game::G18OE::Game, exception: nil)
    script.instance_variable_set(:@mirror, mirror)
    script.instance_variable_set(:@account_of, { "p" => "a" })
    script.instance_variable_set(:@game_id, 1)
    action = { "type" => "pass", "entity" => "p" }

    expect(mirror).to receive(:process_action).with(action.merge("user" => "p"), add_auto_actions: true)
    script.send(:post, "p", { "seq" => 0 }, action, "stock", "Step")
  end
end
