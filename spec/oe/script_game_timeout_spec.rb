# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "net/http"
require "oe/script_game"

# #596: full run 45507429707 (main f481055): S1 and S2 game 3 and 4 ended with exit 1 and no report: a POST
# outlived the client's read timeout (120 s), Net::ReadTimeout escaped the run and the lines "Game end" and
# "Verdict" were never printed. A request that times out is a problem of the run like a rejected action: the
# run stops and the report names the request, the move and the round/step.
RSpec.describe "ScriptGame request timeout (#596)" do
  def script_with(client)
    script = Oe::ScriptGame.new(clients: { "a" => client }, slice: "s2")
    script.instance_variable_set(:@account_of, { "p" => "a" })
    script.instance_variable_set(:@game_id, 1)
    script
  end

  def timing_out_client
    client = Object.new
    def client.call(*) = raise(Net::ReadTimeout, "read timeout")
    client
  end

  it "turns a timed-out POST into a problem that names the move" do
    script = script_with(timing_out_client)
    action = { "type" => "place_token", "entity" => "MZA", "city" => "205-14-0" }

    expect(script.send(:post, "p", { "seq" => 7 }, action, "operating", "Token")).to eq(:timeout)
    problem = script.instance_variable_get(:@ledger).problems.last
    expect(problem.kind).to eq(:timeout)
    expect(problem.detail).to include("operating/Token", "POST /games/1/actions", "place_token", "Net::ReadTimeout")
  end

  it "turns a timed-out GET into a problem and stops the run" do
    script = script_with(timing_out_client)
    state = { "viewer" => "x", "state" => { "meta" => { "round" => { "type" => "stock" } }, "prompt" => { "step" => "BuySellParShares" } } }

    expect(script.send(:view_for, "p", state)).to eq(:timeout)
    expect(script.instance_variable_get(:@ledger).problems.last.detail).to include("GET /games/1", "stock/BuySellParShares")
  end
end
