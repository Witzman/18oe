# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# §11.1.9 Right-of-Way: (1) in its first OR after floating, until Train Phase 3, a RR that could not
# otherwise connect its home station to another town or city may lay one green non-city tile for all its
# remaining tile points; the tile must make the connection. (2) Yellow track in the home hex of a floated
# RR needs its president's permission. PB 5.4/5.5: neither in the two-player game.
describe 'G18OE Right-of-Way (§11.1.9)' do
  include G18OESpecHelpers

  let(:players) { %w[a b c] }
  let(:game) { new_game(players) }
  let(:a) { game.players[0] }
  let(:b) { game.players[1] }

  def lay_rotated!(hex_id, name, rotation)
    tile = game.tiles.find { |t| t.name == name && !t.hex }
    tile.rotate!(rotation)
    game.hex_by_id(hex_id).lay(tile)
    tile
  end

  # A lay action on `hex_id` whose tile has an exit to `edge`, from the step's own offer.
  def lay_with_exit(round, entity, hex_id, edge, color: nil)
    hex = game.hex_by_id(hex_id)
    round.active_step.upgradeable_tiles(entity, hex).each do |tile|
      next if color && tile.color != color

      tile.legal_rotations.each do |rotation|
        tile.rotate!(rotation)
        return Engine::Action::LayTile.new(entity, tile: tile, hex: hex, rotation: rotation) if tile.exits.include?(edge)
      end
    end
    raise "no tile on #{hex_id} with exit #{edge}"
  end

  describe 'permission in a floated RR\'s home hex' do
    # PLM's home is U34; minor B stands in U32 next to it (U32 side 4 faces U34, U34 side 1 faces U32).
    let(:plm) { start_regional!(game, 'PLM', a) }
    let(:minor) { start_minor!(game, 'B', b, 'FR') }

    def operating!
      plm
      minor
      game.hex_by_id('U32').tile.cities.first.place_token(minor, minor.next_token, free: true, check_tokenable: false)
      game.minor_regional_order.delete(minor)
      game.minor_regional_order.unshift(minor)
      game.graph.clear
      round = operating_round_for!(game)
      expect(round.current_entity).to eq(minor)
      act!(round, lay_with_exit(round, minor, 'U32', 4))
      round
    end

    it 'holds the lay and asks the president of the floated RR' do
      expect(plm.floated?).to be(true)
      round = operating!
      act!(round, lay_with_exit(round, minor, 'U34', 1))

      expect(game.hex_by_id('U34').tile.color).to eq(:white)
      expect(round.active_step).to be_a(Engine::Game::G18OE::Step::HomeHexConsent)
      expect(round.active_step.active_entities).to eq([a])
      choices = Oe::LegalActions.new(game).call
      expect(choices.map { |x| [x.class.name.split('::').last, x.entity] }).to contain_exactly(['Choose', a], ['Pass', a])
    end

    it 'lays the tile when the president allows it' do
      round = operating!
      act!(round, lay_with_exit(round, minor, 'U34', 1))
      act!(round, Engine::Action::Choose.new(a, choice: 'allow_home_lay'))

      expect(game.hex_by_id('U34').tile.color).to eq(:yellow)
      expect(round.active_step).to be_a(Engine::Game::G18OE::Step::Track)
      expect(round.active_step.points_left(minor)).to eq(1)
    end

    it 'cancels the lay and closes the hex for this step when the president refuses' do
      round = operating!
      act!(round, lay_with_exit(round, minor, 'U34', 1))
      act!(round, Engine::Action::Pass.new(a))

      expect(game.hex_by_id('U34').tile.color).to eq(:white)
      expect(round.active_step).to be_a(Engine::Game::G18OE::Step::Track)
      expect(round.active_step.available_hex(minor, game.hex_by_id('U34'))).to be_nil
      expect(round.active_step.points_left(minor)).to eq(2)
    end

    it 'needs no permission when the home RR has the same president' do
      own = start_minor!(game, 'C', a, 'FR')
      expect(game.home_hex_consent_needed(own, game.hex_by_id(plm.coordinates), game.tiles.find { |t| t.color == :yellow }))
        .to be_empty
    end

    it 'needs no permission from an un-floated RR' do
      allow(plm).to receive(:floated?).and_return(false)
      expect(game.home_hex_consent_needed(minor, game.hex_by_id('U34'), game.tiles.find { |t| t.color == :yellow })).to be_empty
    end

    context 'with two players (PB 5.4/5.5)' do
      let(:players) { %w[a b] }

      it 'needs no permission' do
        round = operating!
        act!(round, lay_with_exit(round, minor, 'U34', 1))

        expect(game.hex_by_id('U34').tile.color).to eq(:yellow)
      end
    end
  end

  describe 'green tile in the first OR' do
    # MAV's home S60; its neighbours (side: hex) 0 T59, 1 S58, 2 R59, 3 R61, 4 S62 get plain yellow track
    # and 5 T61 a yellow town tile, none of them facing S60: no yellow lay can reach another stop.
    let(:mav) { start_regional!(game, 'MAV', a) }

    def enclose!(town_facing: false)
      { 'T59' => 0, 'S58' => 1, 'R59' => 2, 'R61' => 3, 'S62' => 4 }.each do |hex_id, side|
        facing = (side + 3) % 6
        lay_rotated!(hex_id, '9', (facing + 1) % 6)
      end
      # tile 3: town with exits 0 and 1; rotation 3 gives 3 and 4 (side 2 faces S60), rotation 1 gives 1 and 2
      lay_rotated!('T61', '3', town_facing ? 1 : 3)
    end

    def operating!
      mav
      game.graph.clear
      operating_round_for!(game)
    end

    def home_lay!(round)
      act!(round, lay_with_exit(round, mav, 'S60', 5))
    end

    it 'is offered when the home station cannot reach another stop with yellow track' do
      enclose!
      round = operating!
      expect(round.active_step.right_of_way_available?(mav)).to be(true)
      home_lay!(round)

      tiles = round.active_step.upgradeable_tiles(mav, game.hex_by_id('T61'))
      expect(tiles.map(&:color)).to include(:green)
      offered = Oe::LegalActions.new(game).call.select { |x| x.is_a?(Engine::Action::LayTile) && x.hex.id == 'T61' }
      expect(offered).not_to be_empty
      expect(offered.map(&:tile)).to all(satisfy { |t| t.color == :green && t.exits.include?(2) })
    end

    it 'costs all remaining tile points and connects the home station' do
      enclose!
      round = operating!
      home_lay!(round)
      expect(round.active_step.points_left(mav)).to eq(2)

      act!(round, lay_with_exit(round, mav, 'T61', 2, color: :green))

      expect(game.hex_by_id('T61').tile.color).to eq(:green)
      expect(game.right_of_way_connected?(mav)).to be(true)
      expect(round.active_step).not_to be_a(Engine::Game::G18OE::Step::Track)
    end

    it 'refuses (and does not offer) a green tile that does not make the connection' do
      enclose!
      round = operating!
      # home tile with exits to T61 (side 5) and R59 (side 2)
      step = round.active_step
      home = game.hex_by_id('S60')
      tile, rotation = step.upgradeable_tiles(mav, home).flat_map { |t| t.legal_rotations.map { |r| [t, r] } }
                           .find { |t, r| t.rotate!(r) && (t.exits & [2, 5]).size == 2 }
      act!(round, Engine::Action::LayTile.new(mav, tile: tile, hex: home, rotation: rotation))
      # R59 holds a straight (sides 0 and 3); green 83 at rotation 0 (sides 0, 3, 5) joins S60 but reaches no stop
      green = game.tiles.find { |t| t.name == '83' && !t.hex }
      offered = Oe::LegalActions.new(game).call.select { |x| x.is_a?(Engine::Action::LayTile) && x.hex.id == 'R59' }
      expect(offered).to be_empty

      action = Engine::Action::LayTile.new(mav, tile: green, hex: game.hex_by_id('R59'), rotation: 0)
      expect { act!(round, action) }.to raise_error(Engine::GameError, /Right-of-Way/)
    end

    it 'is not offered when yellow track can reach a stop' do
      enclose!(town_facing: true)
      round = operating!

      expect(round.active_step.right_of_way_available?(mav)).to be(false)
    end

    it 'is not offered on an open map' do
      round = operating!

      expect(round.active_step.right_of_way_available?(mav)).to be(false)
    end

    it 'is not offered after the RR\'s first OR' do
      enclose!
      mav
      game.after_end_of_operating_turn(mav)
      round = operating!

      expect(round.active_step.right_of_way_available?(mav)).to be(false)
    end

    it 'is not offered from Train Phase 3' do
      enclose!
      at_phase!(game, '3')
      round = operating!

      expect(round.active_step.right_of_way_available?(mav)).to be(false)
    end

    context 'with two players (PB 5.4/5.5)' do
      let(:players) { %w[a b] }

      it 'is not offered' do
        enclose!
        round = operating!

        expect(round.active_step.right_of_way_available?(mav)).to be(false)
      end
    end
  end
end
