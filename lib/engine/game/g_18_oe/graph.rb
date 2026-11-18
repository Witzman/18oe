# frozen_string_literal: true

require_relative '../../graph'

module Engine
  module Game
    module G18OE
      class Graph < Engine::Graph
        def clear
          super
          @sea_jumps = nil
          @sea_port_nodes = nil
          @water = nil
          @ferry_costs = nil
        end

        # §11.1.6, §11.2 (#360, #61): the hypothetical train that connects a tile or a token to a station token of the
        # RR also crosses ferries and the sea. The walk over land (super) takes ferries as land (§11.3.7), so they are
        # free there; #price_ferries then counts the paid ones, and Sea crossings extend the result: see #cross_water.
        # The merge graph is an Engine::Graph and stays off the sea (§10.5).
        def compute(corporation, routes_only: false, one_token: nil, &block)
          before = @connected_nodes[corporation]
          super
          nodes = @connected_nodes[corporation]
          return if one_token || nodes.nil? || nodes.equal?(before)

          price_ferries(corporation)
          cross_water(corporation, &block)
        end

        # What the hypothetical train crosses to reach the node: nothing over land, nil if it is not reached.
        def water_cost_to_node(corporation, node)
          return unless connected_nodes(corporation)[node]

          water(corporation)[:nodes][node] || ferry_cost(corporation, :nodes, node)
        end

        # The cheapest way (ferries and sea zones) to reach the hex: over one of its connected sides or to one of its
        # stops. With a tile to be laid there (rotated), only the connected sides it has count: the way to its track
        # (§11.1.6). Approximation: a side of the tile counts even when the new track does not join the track to that
        # side.
        def water_cost_to_hex(corporation, hex, tile = nil)
          edges = connected_hexes(corporation)[hex] || []
          edges &= tile.exits if tile
          costs = water(corporation)[:edges][hex] || {}
          found = edges.map { |edge| costs[edge] || ferry_cost(corporation, :edges, hex, edge) }
          found += hex.tile.city_towns.filter_map { |node| water_cost_to_node(corporation, node) } unless tile
          found.min_by(&:units)
        end

        # The fewest sea zones the hypothetical train crosses to reach the node: 0 over land (also over a ferry,
        # §11.3.7), nil if it is not reached.
        def water_zones_to_node(corporation, node)
          water_cost_to_node(corporation, node)&.zones
        end

        # sea: only the route search passes it (#359): the most sea units a train of the RR can carry
        # (Sea#sea_places). The walk then also crosses the sea (§11.3.4): at a node with a usable port it jumps to
        # every port node of another hex the crossing reaches, the jump standing in the visited paths as a
        # Sea::SeaJump, and walks on from there. Never two jumps without a land hex side between them (§11.3.4,
        # A3 of #60), never out of a node the RR may not pass through (§11.3.6).
        def walk_token(node, skip_paths:, corporation:, sea: nil, **opts, &block)
          # §14.9: the paths of hexes marked by a Brandt & Brandau token are closed to other players' RRs
          # (the route search passes its own skip_paths, so the game's graph_skip_paths is merged here)
          if (blocked = @game.graph_skip_paths(corporation))
            skip_paths = (skip_paths || {}).merge(blocked)
          end
          skip_paths = (skip_paths || {}).merge(@ferry_skip) if @ferry_skip # #61: the walk that prices ferries
          wcf = @game.wcf_placeholder
          return super(node, skip_paths: skip_paths, corporation: corporation, **opts, &block) if !wcf && !sea

          lille = @game.lille_city if wcf
          walker = proc do |path, visited_paths, visited|
            result = block.call(path, visited_paths, visited)
            if result != :abort && wcf && path.nodes.include?(lille) && !visited[lille] &&
               @game.wcf_restricted?(corporation)
              land_paths = @game.wcf_path?(path) ? [] : lille.paths.reject { |other| @game.wcf_path?(other) }
              lille.walk(**opts.merge(visited: visited, visited_paths: visited_paths, corporation: corporation,
                                      skip_paths: (skip_paths || {}).merge(land_paths.to_h { |other| [other, true] }),
                                      counter: Hash.new(0)), &walker)
            end
            if result != :abort && sea && !path.terminal?
              path.nodes.each do |arrived|
                next if visited[arrived] || arrived.blocks?(corporation)

                visited[arrived] = true
                sea_walk(arrived, visited, visited_paths, corporation, skip_paths, sea, opts, block, walker)
                visited.delete(arrived)
              end
            end
            result
          end
          super(node, skip_paths: skip_paths, corporation: corporation, **opts, &walker)
          return unless sea

          # the start node is an end of the route: the walk may begin with a crossing, whatever the node holds
          sea_walk(node, { node => true }, {}, corporation, skip_paths, sea, opts, block, walker)
        end

        # Sea#sea_jumps, kept per node and RR: tiles and tokens do not change while a search runs, and the graph is
        # cleared when they do.
        def sea_jumps(from, corporation)
          @sea_jumps ||= {}
          @sea_port_nodes ||= @game.sea_port_nodes
          @sea_jumps[[from, corporation]] ||= @game.sea_jumps(from, corporation, @sea_port_nodes)
        end

        private

        def water(corporation)
          connected_nodes(corporation)
          @water&.[](corporation) || { nodes: {}, edges: {} }
        end

        # Dijkstra over sea crossings, by sea zones (each crossing counts at least one). From every node reached and
        # not blocked for the RR, a crossing leads to every port node of another hex with a usable port (§11.3.4,
        # §11.3.6) and to every unconnected port arrow the RR may build into (§11.1.3); from a node reached over the
        # sea the walk goes on over land, as the walk of super does. A node reached only as the end of a crossing
        # starts no crossing: a land hex side lies between two crossings (§11.3.4, A3 of #60). Approximation: a
        # node in the hex where the crossing ended counts as not past a land hex side.
        def cross_water(corporation, &block)
          water = (@water ||= {})[corporation] = { nodes: {}, edges: {} }
          sources = @connected_nodes[corporation].keys.reject do |node|
            node.blocks?(corporation) || @game.usable_port_zones(node, corporation).empty?
          end
          return water if sources.empty?

          queue = Hash.new { |h, k| h[k] = [] }
          landings = @game.sea_landings(corporation)
          arrows = @game.sea_arrows(corporation)
          sources.each do |node|
            sea_crossings_from(node, ferry_cost(corporation, :nodes, node), landings, arrows, corporation, queue)
          end

          until queue.empty?
            units = queue.keys.min
            queue.delete(units).each do |target, cost|
              if target.is_a?(Array)
                mark_water_edge(corporation, *target, cost)
              elsif !@connected_nodes[corporation][target]
                land_over_water(corporation, target, cost, &block).each do |node|
                  sea_crossings_from(node, cost, landings, arrows, corporation, queue)
                end
              end
            end
          end
          water
        end

        # #61: the paid ferries (§11.1.6, §11.2.1) are crossed free by the walk of super, so the cost of reaching a
        # node or a side of a hex over them is found here, in a few more walks of the corporation's graph: first with
        # every paid ferry shut, then with the ferries that touch what was reached, the cheapest sets of ferries first
        # (Dijkstra over sets of ferries, each ferry at its distance). What a walk reaches first is what the ferries of
        # that set cost. Only graphs whose walk touches a paid ferry pay for the extra walks; the result of the plain
        # walk is put back afterwards.
        def price_ferries(corporation)
          costs = (@ferry_costs ||= {})[corporation] = { nodes: {}, edges: {} }
          return unless @connected_paths[corporation].each_key.any? { |path| paid_ferry_line?(path) }

          saved = [@connected_hexes[corporation], @connected_nodes[corporation], @connected_paths[corporation],
                   @reachable_hexes[corporation]]
          walk = Engine::Graph.instance_method(:compute)
          queue = { 0 => [[]] }
          seen = { [] => true }
          until queue.empty?
            price = queue.keys.min
            queue.delete(price).each do |allowed|
              @ferry_skip = @game.paid_ferry_skip(allowed)
              walk.bind_call(self, corporation)
              record_ferry_costs(corporation, costs, price)
              adjacent_paid_ferries(@connected_paths[corporation], allowed).each do |ferry|
                set = allowed + [ferry]
                next if seen[(key = set.map(&:object_id).sort)]

                seen[key] = true
                (queue[price + ferry.distance] ||= []) << set
              end
            end
          end
        ensure
          @ferry_skip = nil
          if saved
            @connected_hexes[corporation], @connected_nodes[corporation], @connected_paths[corporation],
              @reachable_hexes[corporation] = saved
          end
        end

        def paid_ferry_line?(path)
          (ferry = @game.ferry_component(path)) && ferry.distance.to_i.positive?
        end

        def record_ferry_costs(corporation, costs, price)
          @connected_nodes[corporation].each_key { |node| costs[:nodes][node] = price unless costs[:nodes].key?(node) }
          @connected_hexes[corporation].each do |hex, edges|
            known = (costs[:edges][hex] ||= {})
            edges.each { |edge| known[edge] = price unless known.key?(edge) }
          end
        end

        # The paid ferries (not yet allowed) that have an end where the walk has track: a path of the end's hex that
        # leaves it over the end's side.
        def adjacent_paid_ferries(paths, allowed)
          found = []
          paths.each_key do |path|
            @game.paid_ferries_at(path.hex.id).each do |ferry|
              next if allowed.include?(ferry) || found.include?(ferry)

              ends = ferry.ends.select { |id, _| id == path.hex.id }
              found << ferry if ends.any? { |_, exit| exit == :offshore || path.exits.include?(exit) }
            end
          end
          found
        end

        # The ferries on the way to a node (kind :nodes, key node) or a side of a hex (kind :edges, key hex and side):
        # none unless #price_ferries found some.
        def ferry_cost(corporation, kind, *key)
          Sea::WaterCost.new(@ferry_costs&.[](corporation)&.dig(kind, *key).to_i, 0)
        end

        def sea_crossings_from(node, cost, landings, arrows, corporation, queue)
          from = @game.usable_port_zones(node, corporation)
          return if from.empty?

          landings.each do |to, to_zones|
            next if to.hex == node.hex || @connected_nodes[corporation][to]

            crossed = @game.fewest_sea_zones(from, to_zones)
            queue[cost.units + (2 * crossed)] << [to, cost.plus_zones(crossed)] if crossed
          end
          arrows.each do |hex, exit, zone|
            next if hex == node.hex

            crossed = @game.fewest_sea_zones(from, [zone])
            queue[cost.units + (2 * crossed)] << [[hex, exit], cost.plus_zones(crossed)] if crossed
          end
        end

        # The train arrives at the node over the sea: as at a token, every side of its hex may take new track; unless
        # the city is full of other RRs' tokens, the walk goes on over land (as in super). Returns the nodes reached
        # that may start another crossing.
        def land_over_water(corporation, landing, cost)
          nodes = @connected_nodes[corporation]
          water = @water[corporation]
          nodes[landing] = true
          water[:nodes][landing] = cost
          @reachable_hexes[corporation][landing.hex] = true
          yield landing if block_given?
          if landing.blocks?(corporation)
            landing.exits.each { |edge| mark_water_edge(corporation, landing.hex, edge, cost) }
            return []
          end

          landing.hex.neighbors.each_key { |edge| mark_water_edge(corporation, landing.hex, edge, cost) }
          reached = []
          paths = @connected_paths[corporation]
          walk_token(landing, visited: nodes.reject { |node, _| node == landing }, corporation: corporation,
                              skip_track: @skip_track, skip_paths: nil, converging_path: false,
                              walk_calls: @walk_calls[corporation]) do |path, _, _|
            next if paths[path]

            paths[path] = true
            @reachable_hexes[corporation][path.hex] = true
            path.nodes.each do |node|
              next if nodes[node]

              nodes[node] = true
              water[:nodes][node] = cost
              yield node if block_given?
              reached << node if node.hex != landing.hex && !node.blocks?(corporation)
            end
            path.exits.each do |edge|
              mark_water_edge(corporation, path.hex, edge, cost)
              neighbor = path.hex.neighbors[edge]
              mark_water_edge(corporation, neighbor, path.hex.invert(edge), cost) if neighbor
            end
          end
          reached
        end

        def mark_water_edge(corporation, hex, edge, cost)
          edges = (@connected_hexes[corporation][hex] ||= [])
          return if edges.include?(edge)

          edges << edge
          (@water[corporation][:edges][hex] ||= {})[edge] = cost
        end

        def sea_walk(from, visited, visited_paths, corporation, skip_paths, limit, opts, block, walker)
          return unless crossed_land_since_sea?(visited_paths)

          sea_jumps(from, corporation).each do |chain, units|
            to = chain[:nodes][1]
            next if units > limit || visited[to]

            jump = Sea::SeaJump.new(chain)
            visited_paths[jump] = true
            result = block.call(jump, visited_paths, visited)
            if result != :abort && !to.blocks?(corporation)
              to.walk(**opts, visited: visited, visited_paths: visited_paths, corporation: corporation,
                              skip_paths: skip_paths, counter: Hash.new(0), &walker)
            end
            visited_paths.delete(jump)
          end
        end

        # A3 of #60: since the last jump the walk has left a hex over a hex side (a ferry counts as land, §11.3.7).
        def crossed_land_since_sea?(visited_paths)
          hex = nil
          visited_paths.keys.reverse_each do |path|
            return false if path.is_a?(Sea::SeaJump)
            return true if hex && path.hex != hex

            hex = path.hex
          end
          true
        end

      end
    end
  end
end
