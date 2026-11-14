# frozen_string_literal: true

module Oe
  class Bot
    # Track laying (#293): extend the network toward the nearest revenue stop
    # it does not reach yet, so a train has a route to run.
    #
    # Scoring per legal lay (hex, tile, rotation), with the engine's own graph
    # (Engine::Graph#connected_nodes):
    # - a tile that brings a new stop (city/town) into the network scores most;
    # - otherwise its new exits (not on the old tile, not joining a
    #   neighbour's track) score by how much closer their neighbour is to the nearest
    #   unreached stop inside the company's track-rights zone (hex distance);
    # - yellow before upgrades (1 track point instead of 2), cheap before dear.
    # Lays without progress are not made (pass). The three best candidates are
    # picked by Pick.weighted (seeded randomness, rule 7: local, no AI).
    #
    # Money: a company without a train keeps the price of the cheapest depot
    # train back (the mandatory 2+2, see #reserve); otherwise it may spend
    # what it has.
    # Before #293 a trainless company passed outright (cash < 200), so no bot
    # laid track in OR 1.1 and many had no route at all in OR 1.2.
    #
    # The sampled LayTile actions the bot is handed (limit 12) are replaced by
    # the full choice space (LegalActions#lay_tile_options), so sampling never
    # hides the one lay that connects.
    class Track
      COLOR_RANK = { white: 0, yellow: 1, green: 2, brown: 3, gray: 4 }.freeze
      NEW_STOP = 100
      FAR = 99

      def initialize(game, rng)
        @game = game
        @rng = rng
      end

      def choose(by_class)
        tiles = by_class["LayTile"]
        pass = by_class["Pass"]&.first
        entity = tiles.first.entity
        candidates = all_lays(entity) || tiles
        affordable = candidates.select { |a| cost(a) <= entity.cash - reserve(entity) }
        if affordable.empty?
          return pass if pass

          return tiles.min_by { |a| cost(a) } # forced
        end

        scored = score_all(entity, affordable)
        progress = scored.select { |s, _| s.positive? }
        return pass if pass && progress.empty?

        Pick.weighted(progress.empty? ? scored : progress, @rng)
      end

      # Cash a company keeps back: the cheapest depot train while it has none,
      # less what its president may chip in (at most half of their cash; the
      # engine lets the president make up a missing 2+2, Step::BuyTrain).
      # Many minors start with exactly the 2+2's price and a home hex with
      # terrain cost; without the president's share they could never lay track.
      def reserve(entity)
        return 0 unless entity.trains.empty?

        president = entity.owner&.player? ? entity.owner.cash / 2 : 0
        [@game.depot.min_depot_price - president, 0].max
      end

      private

      def all_lays(entity)
        step = @game.round.active_step
        return nil unless step.respond_to?(:upgradeable_tiles)

        Oe::LegalActions.new(@game).lay_tile_options(step, entity).flat_map do |hex, tiles|
          tiles.flat_map do |tile, rotations|
            rotations.map { |r| Engine::Action::LayTile.new(entity, tile: tile, hex: hex, rotation: r) }
          end
        end
      end

      # Terrain cost before any zone discount (Game#upgrade_cost would log the discount).
      def cost(action)
        action.hex.tile.upgrades.sum(&:cost)
      end

      def score_all(entity, actions)
        @zone = {}
        graph = @game.graph_for_entity(entity)
        reached = graph.connected_nodes(entity)
        distance = distances(entity, reached)
        actions.map { |a| [score(a, reached, distance), a] }
      end

      def score(action, reached, distance)
        hex = action.hex
        tile = action.tile
        new_exits = exits_of(tile, action.rotation) - hex.tile.exits - joined_edges(hex)
        new_stop = tile.city_towns.any? && hex.tile.city_towns.none? { |n| reached[n] }
        best = new_exits.map { |e| (n = hex.neighbors[e]) ? distance.fetch(n, FAR) : FAR }.min || FAR
        here = distance.fetch(hex, FAR)
        value = new_stop ? NEW_STOP : 0
        value += (here - best) * 10 if best < here
        value - (COLOR_RANK.fetch(tile.color, 0) * 3) - (cost(action) / 10.0)
      end

      # Edges of `hex` where the neighbour's track already runs in: an exit
      # there joins existing track instead of reaching out.
      def joined_edges(hex)
        hex.neighbors.select { |edge, n| n.tile.exits.include?(hex.invert(edge)) }.keys
      end

      def exits_of(tile, rotation)
        tile.edges.map { |e| (e.num + rotation) % 6 }.uniq
      end

      # Hex distance (breadth first over land hexes of the company's zone) to
      # the nearest stop the network does not reach yet.
      def distances(entity, reached)
        targets = @game.hexes.select do |hex|
          next false unless in_zone?(entity, hex)

          stops = hex.tile.city_towns + hex.tile.offboards
          stops.any? && stops.none? { |n| reached[n] }
        end
        dist = targets.to_h { |h| [h, 0] }
        queue = targets.dup
        until queue.empty?
          hex = queue.shift
          next if %i[red blue].include?(hex.tile.color)

          hex.neighbors.each_value do |n|
            next if dist.key?(n) || n.tile.color == :blue || !in_zone?(entity, n)

            dist[n] = dist[hex] + 1
            queue << n
          end
        end
        dist
      end

      def in_zone?(entity, hex)
        @zone[hex] = @game.hex_within_national_region?(entity, hex) unless @zone.key?(hex)
        @zone[hex]
      end
    end
  end
end
