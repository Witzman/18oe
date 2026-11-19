# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/script_game"

# #481: the director steers a rush game towards the S2 targets it never reaches on its own.
RSpec.describe "S2 director steering (#481)" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:script) do
    Oe::ScriptGame.new(clients: {}, slice: "s2").tap do |s|
      s.instance_variable_set(:@mirror, game)
      s.instance_variable_set(:@rush, true)
      s.instance_variable_set(:@targets, targets)
    end
  end
  let(:targets) { %w[stock/MergeMinor/merge] }
  let(:minor) { start_minor!(game, "B", game.players.first, "SP") }

  def prompt(*actions)
    { "actions" => actions, "ranges" => [] }
  end

  describe "starting a merge" do
    let(:take_minor) { { "type" => "choose", "entity" => game.players.first.id, "choice" => minor.id } }
    let(:offer) { { "type" => "choose", "entity" => game.players.first.id, "choice" => "offer_or_merge", "target" => minor.id } }
    let(:pass) { { "type" => "pass", "entity" => game.players.first.id } }

    it "chooses the minor itself while stock/MergeMinor/merge is missing" do
      expect(script.send(:director, "stock", "BuySellParShares", prompt(pass, offer, take_minor))).to eq(take_minor)
    end

    it "leaves the question to the bot once the target is reached" do
      script.instance_variable_set(:@targets, [])
      expect(script.send(:director, "stock", "BuySellParShares", prompt(pass, offer, take_minor))).to be_nil
    end
  end

  it "reads the seats of a game from the slice file, 4 without a `players:`" do
    expect([0, 1].map { |game| Oe::ScriptGame.players("s2", game) }).to eq([4, 3])
    expect(Oe::ScriptGame.players("s1", 0)).to eq(4)
  end
end
