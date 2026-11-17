# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # §11.1.9 Right-of-Way (rulebook p. 30), both parts; PB 5.4/5.5: not in the two-player (aggressive) game.
      #
      # 1. "Until Train Phase 3 begins, during a RR's first OR after floating, it may lay one non-city green
      #    tile at the cost of all of its remaining tile points. This green tile may only be placed if the RR
      #    would not otherwise be able to connect its home station token to at least one other town or city,
      #    via land or Ferry, without using a sea crossing and without causing a first turn bankruptcy. The
      #    green tile must be placed so that the RR is able to connect to another town or city. The RR must
      #    have at least one remaining tile point to do this."
      # 2. "The home token hex of a floated RR may not have yellow track laid on it without the explicit
      #    permission of the RR's president. Un-floated RRs automatically provide this permission."
      #    Built as an interruption to that president (Step::HomeHexConsent, pattern Step::ReserveShare;
      #    workshop #342 A3).
      #
      # ASSUMPTIONS (rule 10, workshop #63):
      # - the green tile is an upgrade of a yellow non-city tile (the case the rule exists for: hostile
      #   yellow track around the home station, PB 5.5); a green tile straight on a white hex is not offered.
      # - "would not otherwise be able to connect" is decided on the map as it is when the green tile is
      #   considered, with the full tile points of the step and the treasury: a search from the home station
      #   over existing track (any owner, ferries included) and over white hexes, each costing the tile
      #   points of a yellow lay and its printed terrain cost (before discounts). Yellow tile geometry and
      #   the tile supply are not modelled: any white hex is assumed to take a yellow tile joining any two
      #   of its sides. A white hex with a town or city ends the search as reached.
      # - red zones count as a "town or city" to connect to.
      module RightOfWay
        RIGHT_OF_WAY_PHASE = '2'

        # PB 5.4/5.5: the two-player game uses the aggressive rules, which drop §11.1.9.
        def right_of_way_rules?
          @players.size > 2
        end

        def after_end_of_operating_turn(operator)
          super
          (@operated_railroads ||= Set.new) << operator.id if operator
        end

        def first_or_after_floating?(entity)
          !(@operated_railroads ||= Set.new).include?(entity.id)
        end

        # Part 1, apart from the step's own state (points left, one tile per step).
        def right_of_way_phase?(entity)
          right_of_way_rules? && entity.corporation? && @phase.name == RIGHT_OF_WAY_PHASE &&
            first_or_after_floating?(entity) && !entity.placed_tokens.empty?
        end

        def right_of_way_hex?(hex)
          hex.tile.color == :yellow && hex.tile.cities.empty? && !metropolis_hex?(hex)
        end

        def right_of_way_tile?(tile)
          tile.color == :green && tile.cities.empty?
        end

        def right_of_way_home_nodes(entity)
          entity.placed_tokens.map(&:city)
        end

        # True when the RR's track (after a trial or real lay) reaches a stop outside its home hexes.
        def right_of_way_connected?(entity)
          homes = right_of_way_home_nodes(entity).map(&:hex)
          graph_for_entity(entity).connected_nodes(entity).keys.any? { |node| !homes.include?(node.hex) }
        end

        # Can the RR reach another town or city with yellow lays, `points` tile points and `cash`?
        def right_of_way_yellow_connection?(entity, points, cash)
          homes = right_of_way_home_nodes(entity)
          home_hexes = homes.map(&:hex)
          queue = []
          seen = {}
          homes.each do |city|
            hex = city.hex
            if hex.tile.color == :white
              queue << [yellow_points(hex), hex.tile.upgrades.sum(&:cost), hex, hex.neighbors.keys]
            else
              exits = hex.tile.paths.select { |path| path.nodes.include?(city) }.flat_map(&:exits)
              queue << [0, 0, hex, exits]
            end
          end

          until queue.empty?
            queue.sort_by! { |pts, money, _, _| [pts, money] }
            pts, money, hex, exits = queue.shift
            next if pts > points || money > cash

            exits.each do |edge|
              neighbor = hex.neighbors[edge]
              next unless neighbor

              border = hex.tile.borders.find { |b| b.edge == edge }
              next if border&.type == :impassable

              entry = (edge + 3) % 6
              key = [neighbor, entry]
              cost = money + border&.cost.to_i
              result = right_of_way_enter(neighbor, entry, home_hexes)
              next unless result

              add_pts = result[:lay] ? yellow_points(neighbor) : 0
              add_money = result[:lay] ? neighbor.tile.upgrades.sum(&:cost) : 0
              total_pts = pts + add_pts
              total_money = cost + add_money
              next if total_pts > points || total_money > cash || !first_round_spend_allowed?(entity, total_money)
              return true if result[:stop]
              next if seen[key] && seen[key].any? { |p, m| p <= total_pts && m <= total_money }

              (seen[key] ||= []) << [total_pts, total_money]
              queue << [total_pts, total_money, neighbor, result[:exits]]
            end
          end
          false
        end

        private

        def yellow_points(hex)
          metropolis_hex?(hex) ? 2 : 1
        end

        # Entering `hex` over its side `entry`: nil when blocked; else whether a yellow lay is needed, whether a
        # stop is reached, and the sides to continue from.
        def right_of_way_enter(hex, entry, home_hexes)
          tile = hex.tile
          # a white hex (preprinted track or not) still takes a yellow tile
          if tile.color == :white
            return { lay: true, stop: !tile.city_towns.empty? && !home_hexes.include?(hex), exits: hex.neighbors.keys - [entry] }
          end

          paths = tile.paths.select { |path| path.exits.include?(entry) }
          return nil if paths.empty?

          stop = paths.any? { |path| path.nodes.any? { |node| !home_hexes.include?(node.hex) } }
          joined = paths.flat_map { |path| path.junction ? tile.paths.select { |p| p.junction == path.junction } : [path] }
          { lay: false, stop: stop, exits: joined.flat_map(&:exits).uniq - [entry] }
        end

        public

        # ---- Part 2: permission for yellow track in a floated RR's home hex --------------------------

        def home_hex_of?(corporation, hex)
          home = corporation.type == :minor ? corporation.tokens.first&.city&.hex&.id : corporation.coordinates
          Array(home).include?(hex.id)
        end

        # Presidents (players) whose permission a yellow lay of `entity` on `hex` needs, in seat order.
        def home_hex_consent_needed(entity, hex, tile)
          return [] unless right_of_way_rules? && hex.tile.color == :white && tile.color == :yellow

          layer = entity.corporation? ? entity.owner : nil
          @corporations.select do |corp|
            corp.floated? && !corp.closed? && corp.owner&.player? && corp.owner != layer && home_hex_of?(corp, hex)
          end.map(&:owner).uniq
        end
      end
    end
  end
end
