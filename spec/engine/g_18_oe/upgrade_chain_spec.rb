# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE several upgrades of one hex in one lay track step (§11.1.1)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let(:phase_steps) { 5 } # Train Phase 7: yellow, green, brown and gray tiles
  let(:major) { start_major!(game, 'LNWR', player) }
  let(:round) do
    major
    phase_steps.times { game.phase.next! }
    enter_round!(game, game.operating_round(1))
  end
  let(:step) { round.active_step }
  # I20 is a plain city next to the LNWR home hex J27
  let(:hex) { game.hex_by_id('I20') }

  def lay!(color)
    tile = step.upgradeable_tiles(major, hex).find { |candidate| candidate.color == color }
    act!(round, Engine::Action::LayTile.new(major, tile: tile, hex: hex, rotation: tile.legal_rotations.first))
    tile
  end

  def offered_colors
    step.upgradeable_tiles(major, hex).map(&:color).uniq
  end

  it 'lets a major lay a yellow tile and upgrade it to green in the same step (double upgrade, 1 + 2 points)' do
    lay!(:yellow)
    lay!(:green)

    expect([hex.tile.color, step.points_left(major)]).to eq([:green, 3])
  end

  it 'lets a major go on to brown (triple upgrade, 1 + 2 + 2 points)' do
    %i[yellow green brown].each { |color| lay!(color) }

    expect([hex.tile.color, step.points_left(major)]).to eq([:brown, 1])
  end

  it 'refuses the gray quadruple upgrade to a major, which has only 6 points (needs 7)' do
    %i[yellow green brown].each { |color| lay!(color) }

    expect(step.upgradeable_tiles(major, hex).map(&:color)).to eq([:gray])
    expect(step.available_hex(major, hex)).to be_nil
    expect { lay!(:gray) }.to raise_error(Engine::GameError, /Cannot lay an upgrade now/)
  end

  it 'allows the quadruple upgrade with 7 points (a national has 9)' do
    allow(game).to receive(:tile_point_budget).and_return(9)
    %i[yellow green brown gray].each { |color| lay!(color) }

    expect([hex.tile.color, step.points_left(major)]).to eq([:gray, 2])
  end

  it 'offers only the next color, never skips one (§11.1.3)' do
    lay!(:yellow)

    expect(offered_colors).to eq([:green])
  end

  describe 'colors not yet available in the Train Phase' do
    let(:phase_steps) { 1 } # Train Phase 3: yellow and green

    it 'stops the chain at the last color of the phase' do
      lay!(:yellow)
      lay!(:green)

      expect(step.upgradeable_tiles(major, hex)).to be_empty
    end
  end

  describe 'Train Phase 2, yellow only' do
    let(:phase_steps) { 0 }

    it 'offers no green after the yellow tile' do
      lay!(:yellow)

      expect(step.upgradeable_tiles(major, hex)).to be_empty
    end
  end

  describe 'with no tile of an intermediate color left' do
    it 'cannot upgrade past the missing color' do
      lay!(:yellow)
      game.tiles.reject! { |tile| tile.color == :green && tile.hex.nil? }

      expect(step.upgradeable_tiles(major, hex)).to be_empty
    end
  end
end
