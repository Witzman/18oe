# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/view"

# #226: players[].shares[].value is what the engine's player_value counts for that holding, so the end-game panel
# can show the value per company instead of a remainder.
RSpec.describe "Oe::View share value (#226)" do
  include G18OESpecHelpers

  let(:game) { new_game }

  it "adds up with cash and open privates to the standings value" do
    player = game.players.first
    start_regional!(game, "LNWR", player, par: 80)
    take_treasury_shares!(game, player, game.corporation_by_id("LNWR"), 2)
    give_company!(player, game.companies.first)

    view = Oe::View.render(game, actions: false)
    game.players.each do |pl|
      v = view[:players].find { |x| x[:id] == pl.id }
      open_privates = v[:companies].reject { |c| c[:face_down] }.sum { |c| c[:value].to_i }
      expect(v[:shares].all? { |s| s[:value].is_a?(Integer) }).to be(true)
      expect(v[:cash] + v[:shares].sum { |s| s[:value] } + open_privates).to eq(game.player_value(pl)), pl.id
    end
    lnwr = view[:players].find { |x| x[:id] == player.id }[:shares].find { |s| s[:corporation] == "LNWR" }
    expect(lnwr[:value]).to be_positive
  end
end
