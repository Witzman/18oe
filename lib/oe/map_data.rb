# frozen_string_literal: true

require "json"
require "engine"
require_relative "game_session"

module Oe
  # The fixed map data (#43), delivered once by GET /map: hex geometry and
  # neighbours, printed tiles, the tile catalog as structured parts, ports and
  # ferries, sea zones, track-rights zones, Orient Express cities, home cities.
  # Everything is read from a fresh `Engine::Game::G18OE::Game` (never from the
  # source text); names are passed through exactly as the engine has them
  # (decision G8: no normalising, no translating). Mutable state (laid tiles,
  # tokens) is not part of it, that is the view model (#35).
  #
  #   Oe::MapData.build           # => Hash (plain JSON types)
  #   Oe::MapData.json(engine_rev) # => memoised String for the endpoint
  module MapData
    SCHEMA = 1
    SQRT3 = Math.sqrt(3)

    # THE coordinate conversion (engine coordinate -> flat world), the only one
    # in the code base. Pointy hexes of side length 1: in a row all columns have
    # the same parity, neighbours in a row are two columns apart, so one column
    # is half a hex width. `row` is the zero-based row (A = 0), `col` the number.
    # World y grows downwards (screen convention). Tilt/rotation is the theme's
    # business; this is flat.
    def self.world(row, col)
      [col * SQRT3 / 2, row * 1.5]
    end

    # Zero-based row index of a coordinate such as "AA82" (A = 0, AA = 26).
    def self.row_index(coordinates)
      Engine::Hex::LETTERS.index(coordinates[/[A-Za-z]+/]) or raise ArgumentError, "bad coordinates #{coordinates}"
    end

    def self.col_number(coordinates)
      coordinates[/\d+/].to_i
    end

    # Unit-free centre-to-neighbour vectors per edge 0..5 (side length 1),
    # derived from the engine's own direction table through `world`. The
    # client does not need to guess the edge numbering.
    def self.edge_vectors
      deltas = Engine::Hex::DIRECTIONS.fetch(:pointy).invert # edge => [dx, dy] in engine double coords
      (0..5).map do |edge|
        dx, dy = deltas.fetch(edge)
        # dx is in half-columns, dy in rows; so world(row, col) with col = dx.
        world(dy, dx).map { |v| v.round(6) }
      end
    end

    module_function

    @mutex = Mutex.new
    @cache = {}

    # Memoised JSON text, keyed by engine_rev (the map only changes with it).
    def json(engine_rev = Oe::GameSession.engine_rev)
      @mutex.synchronize do
        @cache[[SCHEMA, engine_rev]] ||= JSON.generate(build(engine_rev: engine_rev))
      end
    end

    def fresh_game
      Engine::Game::G18OE::Game.new(%w[p0 p1 p2])
    end

    def build(game = nil, engine_rev: nil)
      game ||= fresh_game
      klass = game.class
      sea_zones = klass::SEA_ZONES
      sea_by_hex = sea_zones.each_with_object({}) { |(name, z), h| z[:hexes].each { |id| h[id] = name } }
      zone_hexes = klass::NATIONAL_REGION_HEXES
      hexes = game.hexes.sort_by { |h| [row_index(h.id), col_number(h.id)] }

      {
        schema: SCHEMA,
        engine_rev: engine_rev || Oe::GameSession.engine_rev,
        layout: {
          orientation: klass::LAYOUT.to_s,
          axes: { x: klass::AXES[:x].to_s, y: klass::AXES[:y].to_s },
          rows: hexes.map { |h| row_index(h.id) }.max + 1,
          cols: hexes.map { |h| col_number(h.id) }.max,
          edge_vectors: edge_vectors,
          note: "x = col * sqrt(3)/2, y = row * 1.5 (side length 1, y down); edge i points to neighbors[i]",
        },
        hexes: hexes.map { |h| hex(game, h, sea_by_hex, zone_hexes) },
        tiles: tile_catalog(game),
        ports: ports(klass::PORTS),
        sea_zones: sea_zones.map { |name, z| { name: name, sea: z[:sea].to_s, hexes: z[:hexes] } },
        channel_passages: klass::CHANNEL_PASSAGES.map(&:dup),
        patronage_tiles: klass::PATRONAGE_TILES.map do |id, d|
          { hex: id, group: d[:group].to_s, zone: d[:zone], payouts: d[:payouts].transform_keys(&:to_s) }
        end,
        zones: zones(klass, zone_hexes),
        orient_express: orient_express(game),
        homes: game.corporations.filter_map do |c|
          { corporation: c.id, type: c.type.to_s, hex: c.coordinates } if c.coordinates
        end,
      }
    end

    # `neighbors` is the engine's *geometric* adjacency (`all_neighbors`, edge i
    # -> hex or nil). The engine's `neighbors` is only the passable subset
    # (edges towards blue/gray/red tiles are dropped, #43 measured): not
    # symmetric, so useless for geometry.
    def hex(game, hex, sea_by_hex, zone_hexes)
      tile = hex.tile
      id = hex.id
      row = row_index(id)
      col = col_number(id)
      x, y = world(row, col)
      zones = zone_hexes.select { |_, ids| ids.include?(id) }.keys
      out = {
        id: id, row: row, col: col, x: x.round(6), y: y,
        kind: kind(tile, sea_by_hex[id]),
        color: tile.color.to_s,
        neighbors: (0..5).map { |e| hex.all_neighbors[e]&.id },
      }
      out[:name] = hex.location_name if hex.location_name && !hex.location_name.empty?
      zone = game.region_for_hex(hex)
      out[:zone] = zone if zone
      out[:zones] = zones if zones.size > 1
      out[:sea_zone] = sea_by_hex[id] if sea_by_hex[id]
      out.merge(tile_parts(tile))
    end

    def kind(tile, sea_zone)
      return "offboard" if tile.color == :red
      return "sea" if tile.color == :blue || sea_zone

      "land"
    end

    def tile_catalog(game)
      game.tiles.group_by(&:name).sort_by { |name, _| name }.to_h do |name, copies|
        tile = copies.first
        [name, { color: tile.color.to_s, count: copies.size }.merge(tile_parts(tile))]
      end
    end

    # Structured parts of a tile at rotation 0. Nodes (cities, towns, double
    # towns, offboards, junction) are numbered in the order of the tile's code
    # (`_0`, `_1`, ... in the engine's tile definition); paths refer to them as
    # {node: n}, to edges as {edge: n}. Keys are omitted when empty.
    def tile_parts(tile)
      parts = tile.parts
      inner_towns = parts.grep(Engine::Part::DoubleTown).flat_map(&:towns)
      node_classes = [Engine::Part::City, Engine::Part::Town, Engine::Part::DoubleTown,
                      Engine::Part::Offboard, Engine::Part::Junction]
      nodes = parts.select { |p| node_classes.any? { |c| p.is_a?(c) } && !inner_towns.include?(p) }
      index = nodes.each_with_index.to_h { |n, i| [n, i] }.compare_by_identity
      dt_of = parts.grep(Engine::Part::DoubleTown).each_with_object({}.compare_by_identity) do |dt, h|
        dt.towns.each { |t| h[t] = dt }
      end
      end_of = lambda do |e|
        if e.edge? then { edge: e.num }
        else { node: index.fetch(dt_of[e] || e) }
        end
      end

      paths = parts.grep(Engine::Part::Path).reject { |p| dt_of.key?(p.a) && dt_of.key?(p.b) }.map do |p|
        h = { a: end_of.call(p.a), b: end_of.call(p.b) }
        h[:terminal] = true if p.terminal?
        h
      end.uniq

      out = {}
      add = ->(key, list) { out[key] = list unless list.empty? }
      add.call(:cities, parts.grep(Engine::Part::City).map do |c|
        h = { node: index.fetch(c), slots: c.normal_slots, revenue: revenue(c) }
        h[:loc] = c.loc if c.loc
        h
      end)
      add.call(:towns, (parts.grep(Engine::Part::Town) - inner_towns).map do |t|
        h = { node: index.fetch(t), revenue: revenue(t) }
        h[:loc] = t.loc if t.loc
        h
      end)
      add.call(:double_towns, parts.grep(Engine::Part::DoubleTown).map do |d|
        { node: index.fetch(d), axis: d.axis, revenue_loc: d.revenue_locs, revenue: revenue(d.towns.first) }
      end)
      out[:junction] = index.fetch(tile.junction) if tile.junction
      add.call(:offboards, parts.grep(Engine::Part::Offboard).map { |o| { node: index.fetch(o), revenue: revenue(o) } })
      add.call(:paths, paths)
      add.call(:labels, parts.grep(Engine::Part::Label).map(&:to_s))
      add.call(:terrain, parts.grep(Engine::Part::Upgrade).map { |u| { types: u.terrains.map(&:to_s), cost: u.cost } })
      add.call(:borders, parts.grep(Engine::Part::Border).map do |b|
        h = { edge: b.edge, type: b.type.to_s }
        h[:cost] = b.cost if b.cost
        h
      end)
      add.call(:partitions, parts.grep(Engine::Part::Partition).map do |p|
        { a: p.a, b: p.b, length: p.length, type: p.type.to_s }
      end)
      add.call(:icons, parts.grep(Engine::Part::Icon).map do |i|
        h = { image: i.image }
        h[:name] = i.name if i.name
        h
      end)
      out
    end

    # One number when the revenue is the same in every phase, else {phase => n}.
    def revenue(node)
      rev = node.revenue
      rev.values.uniq.size == 1 && rev.size == Engine::Part::RevenueCenter::PHASES.size ? rev.values.first : rev.transform_keys(&:to_s)
    end

    def ports(table)
      table.flat_map do |hex, edges|
        edges.map do |edge, d|
          h = { hex: hex, edge: edge }
          h[:port] = d[:port].to_s if d[:port]
          h[:ferries] = d[:ferries].map { |f| { hex: f[:hex], exit: f[:exit], distance: f[:distance] } } if d[:ferries]
          h[:dead_end] = true if d[:dead_end]
          h
        end
      end
    end

    # The eight track-rights zones (hex lists) plus zone ids that only exist as
    # a per-city override in the engine (CITY_NATIONAL_ZONE, e.g. "BRS" for
    # Jassy): those carry `city_override: true` and no hex list.
    def zones(klass, zone_hexes)
      listed = zone_hexes.map do |id, ids|
        {
          id: id,
          hexes: ids.size,
          track_rights_cost: klass::TRACK_RIGHTS_COST[id],
          discount: klass::ZONE_DISCOUNT_ZONES.include?(id) ? klass::ZONE_DISCOUNT_RATE : nil,
          asterisked: klass::ASTERISKED_ZONES.include?(id),
        }.compact
      end
      overrides = klass::CITY_NATIONAL_ZONE.values.uniq - zone_hexes.keys
      listed + overrides.map { |id| { id: id, hexes: 0, city_override: true } }
    end

    def orient_express(game)
      klass = game.class
      by_name = klass::LOCATION_NAMES
      origin_ids = game.orient_express_origin_hexes.map(&:id)
      {
        origins: klass::ORIENT_EXPRESS_ORIGINS.map do |name|
          { name: name, hexes: by_name.select { |id, n| n == name && origin_ids.include?(id) }.keys }
        end,
        destinations: klass::ORIENT_EXPRESS_DESTINATIONS.map do |name|
          { name: name, hexes: by_name.select { |_, n| n == name }.keys }
        end,
        bonus: klass::ORIENT_EXPRESS_BONUS,
      }
    end
  end
end
