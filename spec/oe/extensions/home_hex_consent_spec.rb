# frozen_string_literal: true

require_relative "../../engine/engine_helper"
require_relative "../../engine/g_18_oe/helpers"

# EXTENSION, red until the patch exists (#563 Task 8/9, notes/rueckport-differenz/spec-triage-C.md):
# rulebook 11.1.9: yellow track in the home hex of a floated RR needs its president's permission. Chris'
# engine has no such step (his right_of_way_spec covers only the green lay). Patch: a consent step after the
# Track step hold (upstream shape: Engine::Step::Base subclass, `choose`/`pass`).
require "oe/legal_actions"

describe 'G18OE home hex permission (§11.1.9, extension)' do
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
end
