# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# Rewritten on Chris' sea API in the triage (#563 Task 8). The legacy wrapper kept its own port_accesses /
# usable_port_access? / ferry_components structures; Chris reads the PORTS data directly: sea_exit?, port_usable?
# (token of the RR for a private port), usable_ports (adds the track to the arrow, §11.3.6), ferry_links (both ends of
# a ferry, distance) and ferry_track? for the blue paths.
describe 'G18OE port data, usable ports and ferry links (§11.3.4, §11.3.6, §11.3.7)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:ports) { game.class::PORTS }
  let(:corp) { game.corporation_by_id('LNWR') }

  def node(hex_id)
    tile = game.hex_by_id(hex_id).tile
    tile.cities.first || tile.towns.first || tile.offboards.first
  end

  def lay_tile!(hex_id, name, rotation)
    tile = game.tiles.find { |t| t.name == name && !t.hex }
    tile.rotate!(rotation)
    game.hex_by_id(hex_id).lay(tile)
    game.graph.clear
  end

  def token!(hex_id, corporation)
    game.hex_by_id(hex_id).tile.cities.first.place_token(corporation, corporation.next_token, free: true,
                                                                                               check_tokenable: false)
    game.graph.clear
  end

  def usable?(hex_id, exit, corporation)
    game.usable_ports(node(hex_id), corporation).include?([hex_id, exit])
  end

  describe 'port entries' do
    it 'gives every port entry of PORTS a sea zone (§11.3.4)' do
      unresolved = ports.flat_map do |hex_id, exits|
        exits.select { |_, data| data[:port] }.keys.map { |exit| [hex_id, exit] }
      end.select { |hex_id, exit| game.port_sea_zone(hex_id, exit).nil? }

      expect(unresolved).to eq([])
    end

    it 'never offers a dead end (§11.3.4)' do
      expect(game.sea_exit?('P19', 2)).to be(false)
      expect(game.sea_exit?('E44', 0)).to be(false)
      expect(game.sea_exit?('P19', 1)).to be(true)
      expect(game.usable_ports(node('E44'), corp)).to eq([])
    end

    it 'offers no port at a ferry end without a port symbol' do
      expect(game.port_usable?('N31', 1, corp)).to be(false)
    end

    it 'gives Kobenhavn an offshore port into Skagerrak and an onshore one into the Baltic Sea' do
      expect(game.port_sea_zone('I50', :offshore)).to eq('Skagerrak')
      expect(game.port_sea_zone('I50', 5)).to eq('Baltic Sea')
      expect(ports['I50'].values.map { |data| data[:port] }).to eq(%i[public public])
    end

    it 'marks a ferry end with a port symbol as both private port and ferry end (§11.3.7)' do
      expect(ports['AA20'][5]).to include(port: :private)
      expect(game.ferry_links('AA20', 5)).to eq([[['AB27', 1], 1]])
      expect(ports['F49'][0]).to eq(port: :private)
    end

    it 'has no port for a hex without one' do
      expect(ports['B43']).to be_nil
      expect(game.usable_ports(node('B43'), corp)).to eq([])
    end
  end

  describe 'usable ports (PB 4.4)' do
    it 'refuses Goteborg private port without track to the port arrow, even with a token' do
      bjv = game.corporation_by_id('BJV')
      token!('F49', bjv)

      expect(game.port_usable?('F49', 0, bjv)).to be(true)
      expect(usable?('F49', 0, bjv)).to be(false) # the track to the arrow is missing
    end

    it 'allows the Christiania offshore port without any track or token (§11.3.6)' do
      expect(usable?('C48', :offshore, corp)).to be(true)
    end

    it 'allows a public onshore port reached by a preprinted track section' do
      expect(usable?('Z27', 0, corp)).to be(true)
    end

    it 'refuses Valencia private port without track, even with a token' do
      token!('AA20', corp)

      expect(usable?('AA20', 5, corp)).to be(false)
    end

    it 'allows Valencia private port with track only to a RR with a token there (§11.3.6)' do
      lay_tile!('AA20', '57', 2)
      other = game.corporation_by_id('GWR')
      token!('AA20', corp)

      expect(usable?('AA20', 5, corp)).to be(true)
      expect(usable?('AA20', 5, other)).to be(false)
    end

    it 'refuses the private Edinburgh offshore port to a RR without a token there (§11.3.6)' do
      expect(usable?('G26', :offshore, corp)).to be(false)
      token!('G26', corp)

      expect(usable?('G26', :offshore, corp)).to be(true)
    end

    it 'refuses an onshore port when the laid track points elsewhere' do
      lay_tile!('AA20', '57', 0)
      token!('AA20', corp)

      expect(usable?('AA20', 5, corp)).to be(false)
    end
  end

  describe 'ferry links (§11.3.7)' do
    it 'lists both ends of every PORTS ferry with the same distance' do
      asymmetric = ports.flat_map do |hex_id, exits|
        exits.flat_map do |exit, data|
          (data[:ferries] || []).reject do |ferry|
            game.ferry_links(ferry[:hex], ferry[:exit]).include?([[hex_id, exit], ferry[:distance]])
          end.map { |ferry| [hex_id, exit, ferry] }
        end
      end

      expect(asymmetric).to eq([])
    end

    it 'joins the White Cliffs ferry Lille-London with distance 0' do
      expect(game.ferry_links('N31', 1)).to eq([[['M28', 5], 0]])
      expect(game.ferry_links('M28', 5)).to eq([[['N31', 1], 0]])
    end

    it 'joins the Irish Sea ferries of Dublin to its three ports with distance 1 each' do
      expect(game.ferry_links('I20', 4)).to contain_exactly([['J23', 2], 1], [['J25', 2], 1], [['I26', 1], 1])
    end

    it 'reaches the Edinburgh offshore port through its ferry from B41 with distance 1' do
      expect(game.ferry_links('G26', :offshore)).to eq([[['B41', 1], 1]])
    end

    it 'knows the blue ferry path' do
      expect(game.ferry_track?(game.hex_by_id('N29').tile.paths.first)).to be(true)
      expect(game.sea_traffic?(game.hex_by_id('N29').tile.paths.first)).to be(true)
    end
  end
end
