# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE map zones against the board (#194)' do
  include G18OESpecHelpers

  let(:game) { new_game }

  # The board prints a zone name next to the island cities (map.jpg: Palma "Spain", Ajaccio "France",
  # Sassari "Italy"); the playbook calls Palma a Spanish city.
  { 'AB27' => 'SP', 'Z41' => 'FR', 'AB39' => 'IT', 'AC40' => 'IT' }.each do |hex_id, zone|
    it "puts #{hex_id} in the #{zone} track rights zone" do
      expect(game.class::NATIONAL_REGION_HEXES[zone]).to include(hex_id)
      expect(game.region_for_hex(game.hex_by_id(hex_id))).to eq(zone)
    end
  end

  it 'leaves only the Balkan/Ottoman cities (excluded as minor homes) without a national zone' do
    zoned = game.class::NATIONAL_REGION_HEXES.values.flatten
    unzoned = game.hexes.select { |h| h.tile.cities.any? && h.tile.color != :blue && !zoned.include?(h.id) }.map(&:id)
    expect(unzoned - game.class::MINOR_EXCLUDED_HOME_CITIES).to eq([])
  end
end
