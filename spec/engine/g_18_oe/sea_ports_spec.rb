# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE port accesses and ferry components (§11.3.4, §11.3.6, §11.3.7)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:ports) { game.class::PORTS }
  let(:corp) { game.corporation_by_id('LNWR') }

  def node(hex_id)
    tile = game.hex_by_id(hex_id).tile
    tile.cities.first || tile.towns.first || tile.offboards.first
  end

  def access(hex_id, exit)
    game.port_accesses(node(hex_id)).find { |a| a.exit == exit }
  end

  def lay_tile!(hex_id, name, rotation)
    tile = game.tiles.find { |t| t.name == name && !t.hex }
    tile.rotate!(rotation)
    game.hex_by_id(hex_id).lay(tile)
  end

  def token!(hex_id, corporation)
    game.hex_by_id(hex_id).tile.cities.first.place_token(corporation, corporation.next_token, free: true,
                                                                                               check_tokenable: false)
  end

  describe 'port_accesses' do
    it 'gives every port entry in PORTS an access with a sea zone (§11.3.4)' do
      expected = ports.flat_map do |hex_id, exits|
        exits.select { |_, data| data[:port] }.keys.map { |exit| [hex_id, exit] }
      end
      found = ports.keys.select { |hex_id| node(hex_id) }.flat_map do |hex_id|
        game.port_accesses(node(hex_id)).map { |a| [a.hex_id, a.exit] }
      end

      expect(found).to match_array(expected)
      ports.keys.select { |hex_id| node(hex_id) }.each do |hex_id|
        game.port_accesses(node(hex_id)).each { |a| expect(a.zone).not_to be_nil, "#{hex_id} #{a.exit}" }
      end
    end

    it 'never offers a dead end (§11.3.4)' do
      expect(game.port_accesses(node('P19')).map(&:exit)).to contain_exactly(1, 3)
      expect(game.port_accesses(node('E44'))).to eq([])
    end

    it 'offers no access at a ferry end without a port symbol' do
      expect(game.port_accesses(node('N31'))).to eq([])
    end

    it 'gives Kobenhavn an offshore access into Skagerrak and an onshore one into the Baltic Sea' do
      expect(game.port_accesses(node('I50')).map { |a| [a.exit, a.zone, a.kind] })
        .to contain_exactly([:offshore, 'Skagerrak', :public], [5, 'Baltic Sea', :public])
    end

    it 'marks a ferry end with a port symbol as a ferry port (§11.3.7)' do
      expect(access('AA20', 5)).to have_attributes(kind: :private, ferry_port: true, zone: 'Balearic Sea')
      expect(access('F49', 0)).to have_attributes(kind: :private, ferry_port: false)
    end

    it 'has no access for a node without a port' do
      expect(game.port_accesses(node('B43'))).to eq([])
    end
  end

  describe 'usable_port_access? (PB 4.4)' do
    it 'refuses Goteborg private port without track to the port arrow, even with a token' do
      bjv = game.corporation_by_id('BJV')
      token!('F49', bjv)

      expect(game.usable_port_access?(node('F49'), access('F49', 0), bjv)).to be(false)
    end

    it 'allows the Christiania offshore port without any track or token (§11.3.6)' do
      expect(game.usable_port_access?(node('C48'), access('C48', :offshore), corp)).to be(true)
    end

    it 'allows a public onshore port reached by a preprinted track section' do
      expect(game.usable_port_access?(node('Z27'), access('Z27', 0), corp)).to be(true)
    end

    it 'refuses Valencia private port without track, even with a token' do
      token!('AA20', corp)

      expect(game.usable_port_access?(node('AA20'), access('AA20', 5), corp)).to be(false)
    end

    it 'allows Valencia private port with track only to a RR with a token there (§11.3.6)' do
      lay_tile!('AA20', '57', 2)
      other = game.corporation_by_id('GWR')
      token!('AA20', corp)

      expect(game.usable_port_access?(node('AA20'), access('AA20', 5), corp)).to be(true)
      expect(game.usable_port_access?(node('AA20'), access('AA20', 5), other)).to be(false)
    end

    it 'refuses the private Edinburgh offshore port to a RR without a token there (§11.3.6)' do
      expect(game.usable_port_access?(node('G26'), access('G26', :offshore), corp)).to be(false)
      token!('G26', corp)
      expect(game.usable_port_access?(node('G26'), access('G26', :offshore), corp)).to be(true)
    end

    it 'refuses an onshore access when the laid track points elsewhere' do
      lay_tile!('AA20', '57', 0)
      token!('AA20', corp)

      expect(game.usable_port_access?(node('AA20'), access('AA20', 5), corp)).to be(false)
    end
  end

  describe 'ferry_components (§11.3.7)' do
    let(:components) { game.ferry_components }
    let(:ferry_ends) do
      ports.flat_map { |hex_id, exits| exits.select { |_, data| data[:ferries] }.keys.map { |exit| [hex_id, exit] } }
    end

    it 'gives every component exactly one distance' do
      components.each { |c| expect(c.distances.size).to eq(1), c.ends.inspect }
    end

    it 'puts every ferry end of PORTS in exactly one component' do
      ferry_ends.each do |ferry_end|
        expect(components.count { |c| c.ends.include?(ferry_end) }).to eq(1), ferry_end.inspect
      end
      expect(components.flat_map(&:ends)).to match_array(ferry_ends)
    end

    it 'puts both ends of every PORTS ferry in the same component' do
      ports.each do |hex_id, exits|
        exits.each do |exit, data|
          (data[:ferries] || []).each do |ferry|
            component = components.find { |c| c.ends.include?([hex_id, exit]) }
            expect(component.ends).to include([ferry[:hex], ferry[:exit]]), "#{hex_id} #{exit}"
            expect(component.distance).to eq(ferry[:distance])
          end
        end
      end
    end

    it 'leaves no blue ferry line without ferry ends' do
      components.each { |c| expect(c.ends.size).to be >= 2, c.hex_ids.inspect }
    end

    it 'joins the White Cliffs ferry Lille-London with distance 0' do
      component = components.find { |c| c.ends.include?(['N31', 1]) }

      expect(component.ends).to contain_exactly(['N31', 1], ['M28', 5])
      expect(component.distance).to eq(0)
    end

    it 'joins the Irish Sea ferries of Dublin into one component with distance 1' do
      component = components.find { |c| c.ends.include?(['I20', 4]) }

      expect(component.ends).to contain_exactly(['I20', 4], ['J23', 2], ['J25', 2], ['I26', 1])
      expect(component.distance).to eq(1)
    end

    it 'reaches the Edinburgh offshore port through its terminal in G30' do
      component = components.find { |c| c.ends.include?(['G26', :offshore]) }

      expect(component.ends).to contain_exactly(['G26', :offshore], ['B41', 1])
      expect(component.distance).to eq(1)
    end

    it 'finds the component of a blue ferry path' do
      path = game.hex_by_id('N29').tile.paths.first

      expect(game.ferry_component(path).ends).to contain_exactly(['N31', 1], ['M28', 5])
    end
  end
end
