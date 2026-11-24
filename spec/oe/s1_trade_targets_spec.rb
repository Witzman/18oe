# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/script_game"

# #223: the S1 target list asks for the player trade (§10.4, #202): the buyer's offer and the seller's
# answer. The script game keys an offer to another player apart from a purchase from the bank, and the
# director makes the offer while the target is missing (the bot makes none, the seller declines).
RSpec.describe "S1 target list, player trade (§10.4, #223)" do
  include G18OESpecHelpers

  let(:script) { Oe::ScriptGame.new(clients: {}, slice: "s1") }
  let(:combos) { Oe::ScriptGame.slice("s1").fetch("games").flat_map { |g| g["combos"] } }

  # Chris' engine has no seller-consent step: the trade is the single buy_corporation (#563, Task 4a).
  it "lists the offer without a TradeOffer answer step" do
    expect(combos).to include("stock/BuySellParShares/buy_company:trade", "stock/BuySellParShares/buy_corporation")
    expect(combos.grep(/TradeOffer/)).to be_empty
  end

  it "keys a range offer of a trade under buy_company:trade" do
    range = { "type" => "buy_company", "entity" => "x", "company" => "y", "min" => 0, "max" => 9, "step" => 1 }
    expect(script.key("stock", "BuySellParShares", range)).to eq("stock/BuySellParShares/buy_company:trade")
  end

  it "makes an offer from a range while the offer target is missing" do
    script.instance_variable_set(:@targets, ["stock/BuySellParShares/buy_company:trade"])
    script.instance_variable_set(:@ledger, Struct.new(:executed).new({}))
    range = { "type" => "buy_company", "entity" => "alice", "company" => "P1", "min" => 0, "max" => 90, "step" => 1 }
    action = script.send(:director, "stock", "BuySellParShares", { "actions" => [], "ranges" => [range] })
    expect(action).to include("type" => "buy_company", "entity" => "alice", "company" => "P1", "price" => 5)
    # #487: the engine finds the actor by entity_type; without it the action is a dummy player's and is rejected
    expect(action).to include("entity_type" => "player")
    expect(script.send(:offered_in?, action, { "actions" => [], "ranges" => [range] })).to be true
  end
end
