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

  describe "keeping a regional for the consolidation round (#492)" do
    let(:targets) { %w[consolidation/Consolidate/convert] }
    let(:first) { start_regional!(game, "LNWR", game.players.first) }
    let(:second) { start_regional!(game, "GWR", game.players.first) }
    let(:pass) { { "type" => "pass", "entity" => game.players.first.id } }

    def convert(regional)
      { "type" => "convert", "entity" => regional.id }
    end

    it "converts the others and passes when only the held regional is left" do
      held = convert(first)
      other = convert(second)
      expect(script.send(:director, "stock", "BuySellParShares", prompt(pass, held, other))).to eq(other)
      expect(script.send(:director, "stock", "BuySellParShares", prompt(pass, held))).to eq(pass)
    end

    it "takes the convert itself in the consolidation round and holds nothing once the target is reached" do
      expect(script.send(:director, "consolidation", "Consolidate", prompt(pass, convert(first)))).to eq(convert(first))
      script.instance_variable_set(:@targets, [])
      expect(script.send(:director, "stock", "BuySellParShares", prompt(pass, convert(first)))).to be_nil
    end
  end

  describe "filling a corporation with trains for the Phase 4 discard (#224)" do
    let(:targets) { %w[operating/DiscardTrain/discard_train] }
    let(:regional) { start_regional!(game, "LNWR", game.players.first) }
    let(:offers) do
      game.depot.upcoming.first(2).map { |t| { "type" => "buy_train", "entity" => regional.id, "train" => t.id, "price" => t.price, "variant" => nil } }
    end

    it "buys a depot train while the corporation is below its limit in Phase 3" do
      at_phase!(game, "3")
      expect(script.send(:director, "operating", "BuyTrain", prompt(*offers))).to eq(offers.min_by { |a| a["price"] })
    end

    it "leaves a corporation at its limit, a later phase and a reached target alone" do
      at_phase!(game, "3")
      with_trains!(game, regional, "3", "3")
      expect(script.send(:director, "operating", "BuyTrain", prompt(*offers))).to be_nil
      script.instance_variable_set(:@targets, [])
      expect(script.send(:director, "operating", "BuyTrain", prompt(*offers))).to be_nil
    end
  end

  it "reads the seats of a game from the slice file, 4 without a `players:`" do
    expect([0, 1, 2, 3].map { |game| Oe::ScriptGame.players("s2", game) }).to eq([4, 3, 3, 4])
    expect(Oe::ScriptGame.players("s1", 0)).to eq(4)
  end
end
