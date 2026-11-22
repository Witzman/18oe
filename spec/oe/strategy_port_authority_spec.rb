# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/strategy_player"

# #56 part 5: the bot buys a port authority marker (§11.3.5) when its network can cross the sea in an area
# and it keeps a cash buffer (rule 7: simple local rule).
RSpec.describe "Strategy player buying a port authority marker (#56)" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let!(:lnwr) { start_major!(game, "LNWR", game.players[0]) }
  let(:round) { at_phase!(game, "3") && operating_round_for!(game, 1) }

  before do
    with_trains!(game, lnwr, "2+2")
    game.fulfill_train_obligation!(lnwr)
    lnwr.set_cash(600, game.bank)
    round.instance_variable_set(:@entity_index, round.entities.index(lnwr))
    round.instance_variable_set(:@current_operator, lnwr)
  end

  def legal
    Oe::LegalActions.new(game, limit: 200, rng: Random.new(1)).call
  end

  def choice
    Oe::StrategyPlayer.new(game, rng: Random.new(1)).choose(legal)
  end

  def buys_marker?(action)
    action.is_a?(Engine::Action::SpecialBuy)
  end

  def seas(*list)
    allow_any_instance_of(Oe::StrategyPlayer).to receive(:landing_seas).and_return(list)
  end

  it "offers the markers among the legal actions" do
    expect(legal.grep(Engine::Action::SpecialBuy).map { |a| a.item.description }).to include("North Sea port authority")
  end

  it "buys the marker of the area its crossings lie in when cash is left over" do
    seas(:north_sea, :north_sea)
    expect(choice.item.description).to eq("North Sea port authority")
  end

  it "does not buy without a crossing" do
    seas
    expect(buys_marker?(choice)).to be(false)
  end

  it "does not buy when the cash buffer is missing" do
    seas(:north_sea, :north_sea)
    lnwr.set_cash(200, game.bank)
    expect(buys_marker?(choice)).to be(false)
  end
end
