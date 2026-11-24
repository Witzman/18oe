# frozen_string_literal: true

# #600: Brandt & Brandau (RB 14.9, 11.3.10) is Chris' since upstream 0e0220c05 (our patch 0017 and its RemoveHexToken
# are gone). The move enumerator offers what his steps take: the private's lay in G18OE::Step::SpecialTrack and the
# removal of a foreign token as a `choose` (hex id) in the Track step. Setup as in Chris' brandt_brandau_spec.
require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"

describe "Oe::LegalActions with Brandt & Brandau (Chris' engine)" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let(:bbe) { game.company_by_id("BBE") }
  let(:lnwr) { start_major!(game, "LNWR", player) }
  let(:hex) { game.hex_by_id("J23") }

  before do
    game.minor_merged
    give_company!(player, bbe)
    round = enter_round!(game, game.operating_round(1))
    round.entities = [lnwr]
    round.instance_variable_set(:@current_operator, lnwr)
    allow(game).to receive(:cross_water_tile_fee).and_return(0)
  end

  def offers
    Oe::LegalActions.new(game).call
  end

  it "offers the private's lay on its rough hex and the step takes it" do
    lay = offers.find { |a| a.is_a?(Engine::Action::LayTile) && a.entity == bbe && a.hex == hex }

    expect(lay).not_to be_nil
    game.round.process_action(lay)
    expect(hex.assigned?("BBE")).to be(true)
  end

  it "offers another player's RR the removal as a choose and the Track step takes it" do
    special = game.round.steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::SpecialTrack) }
    tile = special.upgradeable_tiles(bbe, hex).first
    special.process_lay_tile(Engine::Action::LayTile.new(bbe, tile: tile, hex: hex, rotation: tile.legal_rotations.first))
    player.companies.delete(bbe)
    give_company!(game.players.last, bbe)
    game.clear_graph

    removal = offers.find { |a| a.is_a?(Engine::Action::Choose) && a.entity == lnwr && a.choice == "J23" }

    expect(removal).not_to be_nil
    game.round.process_action(removal)
    expect(hex.assigned?("BBE")).to be(false)
  end
end
