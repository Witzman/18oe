# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE upgrades must use all usable sides (§11.1.7)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:major) { start_major!(game, 'LNWR', game.players.first) }
  let(:step) do
    major
    5.times { game.phase.next! }
    enter_round!(game, game.operating_round(1)).active_step
  end

  # Builds the hex up to the given tile by placing tiles directly (the connection to the
  # home token is not what is tested here), then returns the tiles offered for the next color.
  def offered_after(hex_id, *tile_names)
    hex = game.hex_by_id(hex_id)
    allow(step).to receive(:hex_neighbors).and_return(hex.neighbors.keys)
    tile_names.each { |name| force_lay!(hex, name) }
    step.upgradeable_tiles(major, hex)
  end

  def force_lay!(hex, name)
    tile = step.upgradeable_tiles(major, hex).find { |candidate| candidate.name == name }
    raise "#{name} is not offered on #{hex.id}" unless tile

    tile.rotate!(tile.legal_rotations.first)
    hex.lay(tile)
  end

  def usable_sides(hex_id)
    game.hex_by_id(hex_id).neighbors.size
  end

  describe 'a normal city upgraded to gray' do
    {
      'AB27' => %w[5 12 OE24],
      'J15' => %w[5 12 OE24],
      'I20' => %w[5 12 OE24],
    }.each do |hex_id, path|
      it "needs a tile with a track section on each of the #{hex_id} usable sides" do
        offered = offered_after(hex_id, *path)

        expect(offered.map { |tile| tile.exits.size }).to eq([usable_sides(hex_id)])
        expect(offered.map(&:color)).to eq([:gray])
      end
    end

    it 'has different usable-side counts in these test hexes (4, 5 and 6)' do
      expect(%w[AB27 J15 I20].map { |hex_id| usable_sides(hex_id) }).to eq([4, 5, 6])
    end
  end

  describe 'a grand city (Y) upgraded to brown and to gray' do
    {
      'N31' => { brown: %w[201 207], gray: %w[201 207 OE31] },
      'G26' => { brown: %w[201 207], gray: %w[201 207 OE32] },
      'U34' => { brown: %w[201 207], gray: %w[201 207 OE33] },
    }.each do |hex_id, paths|
      it "uses all usable sides of #{hex_id} for brown" do
        offered = offered_after(hex_id, *paths[:brown])

        expect(offered.map { |tile| tile.exits.size }.uniq).to eq([usable_sides(hex_id)])
      end

      it "uses all usable sides of #{hex_id} for gray" do
        offered = offered_after(hex_id, *paths[:gray])

        expect(offered.map { |tile| tile.exits.size }.uniq).to eq([usable_sides(hex_id)])
      end
    end
  end

  describe 'a double town upgraded to brown' do
    # M26 has five usable sides: brown OE21 (5 exits) must be the only choice, OE20 (4 exits) is not enough.
    it 'needs a tile with a track section on each usable side of the hex' do
      offered = offered_after('M26', 'OE1', 'OE11')

      expect(offered.map { |tile| tile.exits.size }.uniq).to eq([usable_sides('M26')])
    end

    it 'still offers a brown tile that uses all five sides' do
      offered = offered_after('M26', 'OE1', 'OE11')

      expect(offered.map(&:name)).to include('OE21')
    end
  end

  describe 'a double town upgraded to green' do
    it 'is not restricted to the maximum exits (rule covers brown and gray only)' do
      offered = offered_after('M26', 'OE1')

      expect(offered.map(&:color).uniq).to eq([:green])
      expect(offered.map(&:name)).to include('OE11')
    end
  end

  describe 'a double town upgraded to gray' do
    # The tile set has no gray double-town tile (every gray tile carries a city), so brown is the
    # last step for a double town and the offer after OE21 is legitimately empty. The earlier
    # version of this example only checked "every offered tile has all sides" and passed on that
    # empty offer for the wrong reason (workshop #345).
    it 'has no gray tile to offer after the brown OE21 (empty by design, not by accident)' do
      gray_without_city = game.tiles.select { |tile| tile.color == :gray && tile.cities.empty? && tile.towns.size >= 2 }
      expect(gray_without_city).to be_empty
      expect(game.tiles.select { |tile| tile.color == :gray }).not_to be_empty

      expect(offered_after('M26', 'OE1', 'OE11', 'OE21')).to eq([])
    end
  end

  describe 'a hex with a single town' do
    it 'keeps the base upgrade offer (the rule names double towns only)' do
      hex = game.hex_by_id('M26')
      single = game.tiles.find { |tile| tile.towns.size == 1 && tile.cities.empty? && tile.color == :yellow }
      hex.lay(single)
      allow(step).to receive(:hex_neighbors).and_return(hex.neighbors.keys)
      base = Engine::Step::Track.instance_method(:upgradeable_tiles).bind(step).call(major, hex)

      expect(step.upgradeable_tiles(major, hex).map(&:name)).to eq(base.map(&:name))
    end
  end

  describe 'a double town hex with four usable sides' do
    it 'upgrades to the 4-exit brown tile OE20' do
      expect(offered_after('J29', 'OE1', 'OE11').map(&:name)).to eq(['OE20'])
    end
  end

  describe 'impassable hex sides are not usable (§11.1.3, §11.1.7)' do
    it 'drops the impassable edges from the hex neighbours' do
      hex = game.hex_by_id('N31') # border edge 2 impassable
      expect(hex.neighbors.keys).not_to include(2)
      expect(hex.all_neighbors.keys).to include(2)
    end
  end
end
