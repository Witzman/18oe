# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/view'
require 'oe/legal_actions'
require 'oe/route_search'

# #360 (SC6) with the sea zone part of #61: track and tokens across open water. A hypothetical train with no city
# limit traces the connection from a station token of the RR, also over a sea crossing (§11.1.6, §11.2); an
# unconnected public port arrow it reaches over the sea may be built into (§11.1.3); a private port only with an own
# token in the city (§11.3.6). Fees: £10 a sea zone for a tile, £40 for a token (§11.1.6, §11.2.1).
describe 'G18OE track and tokens across open water (§11.1.3, §11.1.6, §11.2.1)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let(:lnwr) { start_major!(game, 'LNWR', player) }

  def hex(hex_id)
    game.hex_by_id(hex_id)
  end

  def city(hex_id)
    hex(hex_id).tile.cities.first
  end

  def token!(hex_id, corporation)
    city(hex_id).place_token(corporation, corporation.next_token, free: true, check_tokenable: false)
    game.graph.clear
  end

  def lay!(hex_id, name, rotation)
    tile = game.tiles.find { |t| t.name == name && !t.hex }
    tile.rotate!(rotation)
    hex(hex_id).lay(tile)
    game.graph.clear
    tile
  end

  def cash!(corporation, amount)
    diff = amount - corporation.cash
    diff.positive? ? game.bank.spend(diff, corporation) : corporation.spend(-diff, game.bank)
  end

  def rotated(name, rotation)
    game.tiles.find { |t| t.name == name && !t.hex }.tap { |tile| tile.rotate!(rotation) }
  end

  def connected_edges(corporation, hex_id)
    game.graph_for_entity(corporation).connected_hexes(corporation)[hex(hex_id)]
  end

  def track_step
    enter_round!(game, game.operating_round(1)).steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::Track) }
  end

  def token_step
    enter_round!(game, game.operating_round(1)).steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::Token) }
  end

  describe 'a tile across the Baltic from Königsberg' do
    let(:konigsberg_rotation) { 1 } # sides 1 (the public Baltic port arrow) and 4

    before do
      lnwr
      lay!('J63', '57', konigsberg_rotation)
      token!('J63', lnwr)
    end

    it 'reaches the unconnected public port arrow of Danzig, and only it (§11.1.3)' do
      expect(connected_edges(lnwr, 'K60')).to eq([3])
      expect(track_step.tracker_available_hex(lnwr, hex('K60'))).to eq([3])
    end

    context 'without track from Königsberg to its port arrow' do
      let(:konigsberg_rotation) { 0 } # sides 0 and 3

      it 'does not cross the sea (§11.3.6, PB 4.4)' do
        lnwr.tokens.first.remove! # Chris: the home token of LNWR (Irish Sea) reaches the Baltic over sea on its own
        game.graph.clear
        expect(connected_edges(lnwr, 'K60')).to be_nil
      end
    end

    it 'never reaches a private port it holds no token in (§11.1.3: Malmö, §11.3.6)' do
      expect(connected_edges(lnwr, 'I52')).to be_nil # Malmö
      expect(connected_edges(lnwr, 'L53')).to be_nil # Stettin
    end

    it 'charges £10 for the one sea zone of a tile laid into the Danzig arrow (§11.1.6)' do
      tile = rotated('3', 3) # town tile: sides 3 and 4
      expect(tile.exits).to include(3)

      expect(game.cross_water_tile_fee(lnwr, hex('K60'), tile)).to eq(10)
    end

    it 'prices the Danzig hex for the view with the fee (§11.1.6)' do
      expect(game.cross_water_tile_fee(lnwr, hex('K60'), rotated('3', 3))).to eq(10)
    end

    it 'upgrades København over the Baltic arrow for one zone, or over the Skagerrak offshore port for two ' \
       '(§11.1.3 example)' do
      game.phase.next!
      expect(connected_edges(lnwr, 'I50')).to include(1, 3, 5)

      arrow = rotated('622', 1) # sides 1, 3, 4, 5: into the Baltic arrow
      expect(game.cross_water_tile_fee(lnwr, hex('I50'), arrow)).to eq(10)
    end

    it 'charges two zones for a København tile that does not lead into the Baltic arrow' do
      game.phase.next!
      offshore = rotated('208', 0) # sides 0, 1, 3, 4: no track into the Baltic arrow on side 5

      expect(game.cross_water_tile_fee(lnwr, hex('I50'), offshore)).to eq(20)
    end

    # TRIAGE #563 Task 8: wrapper spec (Oe::LegalActions.affordable_lay?, Oe::View), belongs to Task 4b/5; red until then.
    it 'shows the fee in the price of the hex and leaves out a hex the RR cannot pay (view, enumerator)' do
      step = track_step
      tiles = step.upgradeable_tiles(lnwr, hex('K60')).map { |t| [t, t.legal_rotations.dup] }
      price = Oe::View.track_hexes(game, step, lnwr, [[hex('K60'), tiles]]).first

      expect(price[:cost]).to eq(10)
      expect(price[:cost_parts]).to eq([{ label: 'sea', amount: 10 }])

      cash!(lnwr, 9)
      expect(Oe::LegalActions.new(game).affordable_lay?(lnwr, hex('K60'))).to be(false)
    end

    # TRIAGE #563 Task 8: wrapper spec (Oe::RouteSearch), fate decided in Task 6 (RouteSearch entfaellt -> AutoRouter); red on purpose.
    it 'does not start the route search at a stop reached over the sea' do
      with_trains!(game, lnwr)
      expect(game.graph.connected_nodes(lnwr)).to include(city('I50')) # computed before the spy
      search = Oe::RouteSearch.new(game)
      nodes = []
      allow(game.graph).to receive(:walk_token).and_wrap_original do |original, node, **opts, &block|
        nodes << node
        original.call(node, **opts, &block)
      end
      search.path(lnwr.trains, lnwr, walk_limit: 50)

      expect(nodes).not_to include(city('I50'))
    end

    it 'charges nothing where the RR reaches over land (§11.1.6)' do
      expect(game.cross_water_tile_fee(lnwr, hex('J63'), rotated('3', 0))).to eq(0)
    end

    it 'pays the fee when the tile is laid, in the log' do
      cash!(lnwr, 500)
      step = track_step
      game.round.instance_variable_set(:@entities, [lnwr])
      tile = game.tiles.find { |t| t.name == '3' && !t.hex }
      rotation = step.legal_tile_rotations(lnwr, hex('K60'), tile).find do |r|
        tile.rotate!(r)
        tile.exits.include?(3)
      end
      expect(rotation).not_to be_nil

      step.lay_tile_action(Engine::Action::LayTile.new(lnwr, tile: tile, hex: hex('K60'), rotation: rotation))

      expect(lnwr.cash).to eq(490)
      expect(game.log.map(&:message).join("\n")).to include('spends £10 and lays tile')
    end
  end

  describe 'a token from London over København into Malmö (§11.2.1 example)' do
    before do
      lnwr
      token!('M28', lnwr) # London: its offshore port lies in the English Channel
      lay!('I50', '208', 0) # København: sides 0, 1, 3, 4; side 4 leads to Malmö
      lay!('I52', '57', 1) # Malmö: sides 1 and 4
    end

    it 'reaches Malmö by land from København, which it reaches over three sea zones' do
      nodes = game.graph_for_entity(lnwr).connected_nodes(lnwr)

      expect(nodes).to include(city('I50'), city('I52'))
      expect(game.cross_water_token_fee(lnwr, city('I52'))).to eq(120)
    end

    it 'charges £40 a zone on top of the token price' do
      cash!(lnwr, 1000)
      step = token_step
      token = lnwr.next_token
      price = token.price

      token_step.process_place_token(Engine::Action::PlaceToken.new(lnwr, city: city('I52'), slot: 0))

      expect(city('I52').tokened_by?(lnwr)).to be(true)
      expect(lnwr.cash).to eq(1000 - price - 120)
    end

    it 'refuses the token when the RR cannot pay the fee as well (§11.2)' do
      cash!(lnwr, lnwr.next_token.price + 119)

      action = Engine::Action::PlaceToken.new(lnwr, city: city('I52'), slot: 0)
      expect { token_step.process_place_token(action) }.to raise_error(Engine::GameError, /cannot afford/)
    end

    it 'shows the token price with the fee (view)' do
      token = lnwr.next_token

      expect(Oe::View.token_price(game, token_step, token, city('I52'))).to eq(token.price + 120)
    end

    it 'charges nothing for a token reached over land' do
      expect(game.cross_water_token_fee(lnwr, city('M28'))).to eq(0)
    end
  end

  it 'keeps the merge graph off the sea (§10.5)' do
    expect(game.merge_graph).to be_an_instance_of(Engine::Graph)
  end
end
