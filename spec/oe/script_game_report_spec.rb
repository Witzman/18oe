# frozen_string_literal: true

require "spec_helper"
require "oe/script_game"

# #596: a failed scripted game must say why in its own output (end reason, bank, verdict).
RSpec.describe Oe::ScriptGame::Report do
  def result(**over)
    Oe::ScriptGame::Result.new({ slice: "s2 / g1", status: :finished, actions: 10, seed: 1, game_id: 1,
                                 ledger: Oe::ScriptGame::Ledger.new, missing: [], finished: true, standings: [],
                                 seconds: 1.0, detail: nil, targets: [], phase: "3 (turn 2)",
                                 end_reason: "bankrupt", bank_cash: 0 }.merge(over)).then { |r| described_class.lines(r).join("\n") }
  end

  it "names the end reason and the bank" do
    expect(result).to include("Game end: bankrupt, bank cash 0")
  end

  it "says FAILED with the missing targets" do
    expect(result(missing: ["a/b/c"])).to include("Verdict: FAILED (1 target combination missing)")
  end

  it "says OK when nothing is wrong" do
    expect(result).to include("Verdict: OK")
  end
end
