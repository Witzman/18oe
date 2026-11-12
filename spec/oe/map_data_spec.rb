# frozen_string_literal: true

require "spec_helper"
require "oe/map_data"

RSpec.describe Oe::MapData do
  # One fresh game and one build for all examples (about 0.3 s).
  before(:all) do
    @game = described_class.fresh_game
    @data = described_class.build(@game)
    @hexes = @data[:hexes]
    @by_id = @hexes.to_h { |h| [h[:id], h] }
  end

  let(:data) { @data }
  let(:hexes) { @hexes }
  let(:by_id) { @by_id }

  it "is plain JSON (round trip unchanged, no object dumps)" do
    text = JSON.generate(data)
    expect(JSON.parse(text)).to eq(JSON.parse(JSON.generate(JSON.parse(text))))
    expect(text).not_to include("#<")
  end

  describe "hex ids" do
    it "are exactly the engine's hex ids" do
      expect(hexes.map { |h| h[:id] }).to match_array(@game.hexes.map(&:id))
      expect(hexes.size).to eq(1492)
    end

    it "carry row (A = 0) and col (the number) of the engine coordinate" do
      expect(by_id["A2"].values_at(:row, :col)).to eq([0, 2])
      expect(by_id["AA82"].values_at(:row, :col)).to eq([26, 82])
      expect(by_id["AH87"].values_at(:row, :col)).to eq([33, 87])
    end
  end

  describe "kinds (measured on the engine, see #43)" do
    it "counts land, sea and off-board hexes" do
      expect(hexes.map { |h| h[:kind] }.tally).to eq("land" => 828, "sea" => 646, "offboard" => 18)
    end

    it "marks every red tile as off-board and every sea-zone hex as sea or off-board" do
      expect(hexes.select { |h| h[:color] == "red" }.map { |h| h[:kind] }.uniq).to eq(["offboard"])
      in_zone = hexes.select { |h| h[:sea_zone] }
      expect(in_zone.size).to eq(631)
      expect(in_zone.map { |h| h[:kind] }.uniq - %w[sea offboard]).to be_empty
    end
  end

  describe "known facts from the rulebook and input/" do
    it "has 24 regional home cities on existing hexes with a city" do
      homes = data[:homes].select { |h| h[:type] == "regional" }
      expect(homes.size).to eq(24)
      homes.each { |h| expect(by_id.fetch(h[:hex])).to have_key(:cities) }
    end

    it "has Constantinople on AA82 and prints Liverpool, Manchester, Athinai" do
      expect(by_id["AA82"][:name]).to eq("Constantinople")
      expect(data[:orient_express][:destinations].first[:hexes]).to include("AA82")
      expect(by_id["J25"][:name]).to eq("Liverpool")
      expect(by_id["J27"][:name]).to eq("Manchester")
      expect(by_id["AE72"][:name]).to eq("Athínai") # exactly as in the engine (decision G8)
      %w[J25 J27 AE72].each { |id| expect(by_id[id][:color]).to eq("yellow") }
    end

    it "passes location names through unchanged" do
      expect(hexes.filter_map { |h| [h[:id], h[:name]] if h[:name] }.to_h).to eq(@game.class::LOCATION_NAMES)
    end

    it "has eight track-rights zones with costs, plus the single-city override BRS" do
      regular = data[:zones].reject { |z| z[:city_override] }
      expect(regular.map { |z| z[:id] }).to match_array(%w[UK SC FR PHS AH IT SP RU])
      expect(regular.map { |z| z[:track_rights_cost] }).to all(be_a(Integer))
      expect(data[:zones].map { |z| z[:id] }).to include("BRS")
    end

    it "gives every land city a zone except the nine the engine leaves without" do
      cities = hexes.select { |h| h[:kind] == "land" && h[:cities] }
      without = cities.reject { |h| h[:zone] }.map { |h| h[:id] }
      # MINOR_EXCLUDED_HOME_CITIES minus Jassy (S76, zone BRS), plus Palma (AB27)
      expect(without).to match_array(%w[W64 W74 Y70 AA62 AB69 AD79 AE72 AA82 AB27])
      expect(cities.filter_map { |h| h[:zone] }.uniq - data[:zones].map { |z| z[:id] }).to be_empty
    end

    it "has 19 sea zones with the engine's hexes and channel passages between named zones" do
      expect(data[:sea_zones].size).to eq(19)
      expect(data[:sea_zones].flat_map { |z| z[:hexes] }.size).to eq(631)
      names = data[:sea_zones].map { |z| z[:name] }
      data[:channel_passages].each { |pair| expect(names).to include(*pair) }
    end

    it "carries patronage tiles on existing hexes" do
      expect(data[:patronage_tiles].size).to eq(@game.class::PATRONAGE_TILES.size)
      data[:patronage_tiles].each { |t| expect(by_id).to have_key(t[:hex]) }
    end

    it "lists the Orient Express origins on hexes with that name" do
      data[:orient_express][:origins].each do |o|
        expect(o[:hexes]).not_to be_empty
        o[:hexes].each { |id| expect(by_id[id][:name]).to eq(o[:name]) }
      end
    end
  end

  describe "neighbours" do
    it "has six slots per hex, edge i pointing to neighbors[i], and is symmetric" do
      hexes.each do |h|
        expect(h[:neighbors].size).to eq(6)
        h[:neighbors].each_with_index do |n, edge|
          next unless n

          expect(by_id.fetch(n)[:neighbors][(edge + 3) % 6]).to eq(h[:id])
        end
      end
    end

    it "agrees with the engine" do
      @game.hexes.each do |eh|
        expect(by_id[eh.id][:neighbors]).to eq((0..5).map { |e| eh.all_neighbors[e]&.id })
        expect(eh.neighbors.keys - eh.all_neighbors.keys).to be_empty # passable is a subset
      end
    end
  end

  describe "coordinate conversion (the only place: Oe::MapData.world)" do
    it "puts every neighbour pair sqrt(3) apart, along the same edge vector everywhere" do
      vectors = data[:layout][:edge_vectors]
      expect(vectors.size).to eq(6)
      hexes.each do |h|
        h[:neighbors].each_with_index do |n, edge|
          next unless n

          o = by_id[n]
          dx = o[:x] - h[:x]
          dy = o[:y] - h[:y]
          expect(Math.hypot(dx, dy)).to be_within(1e-5).of(Math.sqrt(3))
          expect(dx).to be_within(1e-5).of(vectors[edge][0])
          expect(dy).to be_within(1e-5).of(vectors[edge][1])
        end
      end
    end

    it "is x = col*sqrt(3)/2, y = row*1.5, and the delivered x/y use it" do
      expect(described_class.world(0, 2)).to eq([Math.sqrt(3), 0.0])
      expect(described_class.world(2, 0)).to eq([0.0, 3.0])
      hexes.each do |h|
        x, y = described_class.world(h[:row], h[:col])
        expect(h[:x]).to be_within(1e-6).of(x)
        expect(h[:y]).to eq(y)
      end
    end

    it "gives opposite edges opposite vectors" do
      v = data[:layout][:edge_vectors]
      3.times do |i|
        expect(v[i][0] + v[i + 3][0]).to be_within(1e-5).of(0)
        expect(v[i][1] + v[i + 3][1]).to be_within(1e-5).of(0)
      end
    end
  end

  describe "tile catalog and printed tiles" do
    let(:tiles) { data[:tiles] }

    it "lists every tile name of the engine with its count" do
      expect(tiles.keys).to match_array(@game.tiles.map(&:name).uniq)
      expect(tiles.values.sum { |t| t[:count] }).to eq(@game.tiles.size)
      expect(tiles["8"][:count]).to eq(@game.class::TILES.fetch("8"))
    end

    it "describes paths as edge or node ends that exist on the tile" do
      (tiles.values + hexes).each do |t|
        nodes = %i[cities towns double_towns offboards].flat_map { |k| (t[k] || []).map { |c| c[:node] } }
        nodes << t[:junction] if t[:junction]
        (t[:paths] || []).each do |p|
          %i[a b].each do |side|
            e = p[side]
            if e.key?(:edge) then expect(0..5).to cover(e[:edge])
            else expect(nodes).to include(e[:node])
            end
          end
        end
      end
    end

    it "numbers nodes in code order and keeps double towns whole (OE5, OE9)" do
      expect(tiles["OE5"][:cities].map { |c| c[:node] }).to eq([0, 1])
      expect(tiles["OE5"][:paths]).to include({ a: { edge: 0 }, b: { node: 0 } }, { a: { node: 1 }, b: { edge: 3 } })
      dt = tiles["OE9"]
      expect(dt[:double_towns]).to eq([{ node: 0, axis: 2.0, revenue_loc: [2.0, 5.0], revenue: 10 }])
      expect(dt[:paths].size).to eq(4)
      expect(dt[:paths].map { |p| p[:b] }.uniq).to eq([{ node: 0 }])
    end

    it "marks terminal paths and gives phase revenues as a hash" do
      expect(hexes.flat_map { |h| h[:paths] || [] }.any? { |p| p[:terminal] }).to be(true)
      expect(by_id["D25"][:offboards].first[:revenue]).to eq("yellow" => 20, "green" => 40, "brown" => 50, "gray" => 50)
      expect(by_id["J25"][:cities].first[:revenue]).to eq(30)
    end

    it "prints terrain with its cost on hexes" do
      terrain = hexes.flat_map { |h| h[:terrain] || [] }
      expect(terrain.flat_map { |t| t[:types] }.uniq).to match_array(%w[hill mountain water river lake])
      expect(terrain.map { |t| t[:cost] }).to all(be_a(Integer))
    end
  end

  describe "ports and ferries" do
    it "lists every port entry of the engine with its ferries" do
      expect(data[:ports].size).to eq(@game.class::PORTS.values.sum(&:size))
      ab27 = data[:ports].select { |p| p[:hex] == "AB27" }
      expect(ab27.find { |p| p[:edge] == 2 }[:ferries]).to eq([{ hex: "Z27", exit: 0, distance: 0 }])
      expect(data[:ports].find { |p| p[:hex] == "Z41" && p[:edge] == 1 }[:dead_end]).to be(true)
      expect(data[:ports].find { |p| p[:hex] == "AD1" }[:port]).to eq("public")
      data[:ports].each { |p| expect(by_id).to have_key(p[:hex]) }
    end
  end

  describe "upgrade paths (#201)" do
    let(:tiles) { data[:tiles] }
    let(:game) { described_class.fresh_game }
    let(:labelled) { game.hexes.select { |h| h.tile.label } }
    let(:neutral) { game.hexes.find { |h| h.tile.color == :white && !h.tile.label } }

    it "gives every one of the 76 catalog tiles an upgrades_to list of catalog names" do
      expect(tiles.size).to eq(76)
      tiles.each do |name, t|
        expect(t[:upgrades_to]).to be_an(Array), name
        expect(t[:upgrades_to]).to eq(t[:upgrades_to].sort)
        expect(tiles.keys).to include(*t[:upgrades_to]) unless t[:upgrades_to].empty?
        expect(tiles.keys).to include(*t[:upgrades_to_at].keys) if t[:upgrades_to_at]
        expect(t[:upgrades_to] & (t[:upgrades_to_at] || {}).keys).to be_empty
      end
    end

    it "matches the engine (all_potential_upgrades) for every tile on every hex it can lie on" do
      checked = 0
      game.tiles.group_by(&:name).each do |name, copies|
        tile = copies.first
        contexts = tile.label ? [neutral] + labelled : [neutral]
        entry = tiles.fetch(name)
        contexts.each do |hex|
          tile.hex = hex
          engine = game.send(:all_potential_upgrades, tile).map(&:name)
          mine = entry[:upgrades_to] + (entry[:upgrades_to_at] || {}).select { |_, ids| ids.include?(hex.id) }.keys
          expect(mine).to match_array(engine), "#{name} on #{hex.id}"
          checked += 1
        end
        tile.hex = nil
      end
      expect(checked).to be > 76
    end

    it "only goes up one colour, keeps the pre-printed track and the city/town counts" do
      colors = Engine::Tile::COLORS.map(&:to_s)
      by_name = game.tiles.group_by(&:name).transform_values(&:first)
      tiles.each do |name, t|
        from = by_name.fetch(name)
        (t[:upgrades_to] + (t[:upgrades_to_at] || {}).keys).each do |to_name|
          to = by_name.fetch(to_name)
          expect(colors.index(to.color.to_s)).to eq(colors.index(t[:color]) + 1), "#{name} -> #{to_name}"
          expect(from.paths_are_subset_of?(to.paths)).to be(true)
          expect(from.towns.size).to eq(to.towns.size)
          expect(from.double_towns.size).to eq(to.double_towns.size)
        end
      end
    end

    it "marks the hex-dependent label upgrades with the hexes they apply to" do
      at = tiles["201"][:upgrades_to_at]
      expect(at["OE12"]).to eq(%w[K26 R55 Y14])
      expect(at["OE13"]).to eq(%w[M50])
      expect(at["OE14"]).to eq(%w[AA82])
      expect(at["OE18"]).to eq(%w[C74])
      expect(at["OE16"]).to eq(%w[AB51])
      expect(tiles["201"][:upgrades_to]).to eq(%w[207 208 622])
      expect(tiles["OE4"][:upgrades_to_at]["OE17"]).to eq(%w[Q30])
      expect(tiles["3"][:upgrades_to_at]).to be_nil
      expect(labelled.map { |h| h.id }).to include(*at.values.flatten)
    end

    it "carries the first phase in which the colour may be laid" do
      expect(tiles["3"][:phase]).to eq("2")
      expect(tiles["141"][:phase]).to eq("3")
      expect(tiles["145"][:phase]).to eq("5")
      expect(tiles["OE34"][:phase]).to eq("7")
      expect(tiles.values.map { |t| t[:phase] }.compact.size).to eq(76)
    end

    it "gives bare white hexes one shared list and printed cities/towns their own" do
      blank = data[:blank_upgrades_to]
      expect(blank).to eq(%w[7 8 9])
      own = hexes.select { |h| h[:upgrades_to] }
      expect(own.size).to eq(272)
      expect(own.map { |h| h[:upgrades_to] }.flatten - tiles.keys).to be_empty
      bare = hexes.select { |h| h[:color] == "white" && !h[:upgrades_to] && !h[:cities] && !h[:towns] && !h[:paths] }
      expect(bare).not_to be_empty
      game.hexes.select { |h| h.tile.color == :white && described_class.blank_tile?(h.tile) }.each do |eh|
        expect(game.send(:all_potential_upgrades, eh.tile).map(&:name)).to match_array(blank), eh.id
      end
      own.each do |h|
        eh = game.hex_by_id(h[:id])
        expect(h[:upgrades_to]).to match_array(game.send(:all_potential_upgrades, eh.tile).map(&:name)), h[:id]
      end
    end
  end

  describe ".json" do
    it "is memoised per engine_rev" do
      a = described_class.json("rev-a")
      expect(described_class.json("rev-a")).to equal(a)
      expect(JSON.parse(a)["engine_rev"]).to eq("rev-a")
    end
  end
end

RSpec.describe "GET /map" do
  def login
    post "/login", { account: "alice", code: "" }.to_json, "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "127.0.0.1"
  end

  it "requires login" do
    get "/map"
    expect(last_response.status).to eq(401)
    expect(JSON.parse(last_response.body)["error"]).to eq("login_required")
  end

  it "serves the map with an ETag derived from the engine revision, and 304 on a match" do
    login
    expect(last_response.status).to eq(200)
    get "/map"
    expect(last_response.status).to eq(200)
    expect(last_response.content_type).to include("application/json")
    etag = last_response.headers["ETag"]
    expect(etag).not_to be_nil
    expect(JSON.parse(last_response.body)["hexes"].size).to eq(1492)

    get "/map", {}, "HTTP_IF_NONE_MATCH" => etag
    expect(last_response.status).to eq(304)
    expect(last_response.body).to be_empty
  end
end
