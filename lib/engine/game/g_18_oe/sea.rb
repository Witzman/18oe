# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # Ports and ferries as data (§11.3.4, §11.3.6, §11.3.7), read from Map::PORTS and the blue ferry lines
      # of the map, and sea crossings as route chains without track (§11.3.4, #357).
      module Sea
        # A place where a train may leave a node for a sea zone, or come in from one (§11.3.4).
        # exit: the hex side of the port arrow, or :offshore (§11.3.6: joined to the city without track).
        # kind: :public or :private. ferry_port: the port arrow is also a ferry end (§11.3.7, same hex side).
        PortAccess = Struct.new(:hex_id, :exit, :zone, :kind, :ferry_port)

        # The blue ferry lines joined to each other (§11.3.7). ends: the [hex_id, exit] ferry ends of PORTS
        # (land side, exit may be :offshore) this ferry serves; distances: the distance numbers PORTS gives them.
        FerryComponent = Struct.new(:hex_ids, :ends, :distances) do
          # A ferry has one distance oval; the data spec checks that every component has exactly one.
          def distance
            distances.first
          end
        end

        # The port accesses of the hex of a city, town or red zone; dead ends never (§11.3.4). The data is
        # per hex: whether a given node of the hex reaches an onshore arrow is usable_port_access?'s question.
        def port_accesses(node)
          hex_id = node.hex.id
          (self.class::PORTS[hex_id] || {}).filter_map do |exit, data|
            next unless data[:port]

            PortAccess.new(hex_id, exit, port_sea_zone(hex_id, exit), data[:port], !data[:ferries].nil?)
          end
        end

        # §11.3.4/§11.3.6, PB 4.4: an onshore arrow needs a track section from the node to it on the current
        # tile; an offshore port needs none. A private port also needs a token of the corporation in the city.
        def usable_port_access?(node, access, corporation)
          return false if access.exit != :offshore && !node.exits.include?(access.exit)
          return true if access.kind == :public

          !corporation.nil? && node.hex.tile.cities.any? { |city| city.tokened_by?(corporation) }
        end

        # A stretch of a route's sea traffic that counts against the city limit: a sea crossing's zones or a ferry's
        # distance. hex_ids: the land hexes of its ports or ferry ends, where a token can reach it (assumption A2 of #60).
        SeaTarget = Struct.new(:units, :hex_ids)

        # What takes units off the targets of one train: up to `amount` units of one target whose hex_ids hold one of
        # its hex_ids. A port token is one (§11.3.5); Port Authority, Minor H and the Star Harbor token (#56, #73, #79)
        # join through extra_sea_reducers.
        SeaReducer = Struct.new(:amount, :hex_ids)

        # §11.3.3, §11.3.7: the places a route's sea traffic takes from the city limit. Each ferry the route rides
        # counts its full distance (0 or 1), even when the train rides only part of it; each sea crossing counts
        # its sea zones (§11.3.4); the port tokens of the route take units off again (§11.3.5, §11.3.7).
        def sea_units(route)
          targets = sea_targets(route)
          return 0 if targets.empty?

          units = targets.map(&:units)
          units.sum - max_sea_reduction(units.dup, targets, sea_reducers(route))
        end

        def sea_targets(route)
          ferries = route.paths.filter_map { |path| ferry_component(path) }.uniq(&:object_id)
          ferry_targets = ferries.select { |ferry| ferry.distance.to_i.positive? }
                                 .map { |ferry| SeaTarget.new(ferry.distance, ferry.ends.map(&:first).uniq) }
          crossing_targets = sea_crossings(route).map do |chain|
            SeaTarget.new(chain[:sea][:zones], [chain[:sea][:from].hex_id, chain[:sea][:to].hex_id])
          end
          ferry_targets + crossing_targets
        end

        def sea_reducers(route)
          port_token_reducers(route) + extra_sea_reducers(route)
        end

        # §11.3.5: a train that runs through a city with a token of its own RR spends that token once, on one
        # stretch of sea next to the city: 1 unit in phase 2 to 6, 2 in phase 7 and 8. Assumption A2 of #60:
        # next to the token means a port of the city's hex, also when the train only passes through it by land.
        def port_token_reducers(route)
          corporation = route.corporation
          amount = route.phase.name.to_i >= 7 ? 2 : 1
          nodes = (route.paths.flat_map(&:nodes) + route.chains.flat_map { |chain| chain[:nodes] }).uniq
          nodes.select { |node| node.city? && node.tokened_by?(corporation) }
               .map { |node| SeaReducer.new(amount, [node.hex.id]) }
        end

        # Hook for reductions that are not a port token (#56 Port Authority, #73 Minor H, #79 Star Harbor token):
        # return SeaReducer objects for this train. Nothing yet.
        def extra_sea_reducers(_route)
          []
        end

        # The most units the reducers take off the targets, each reducer on one target, each target at most down to
        # zero. Few tokens and few stretches per route, so every assignment is tried: no greedy argument needed.
        def max_sea_reduction(left, targets, reducers)
          reducer, *rest = reducers
          return 0 unless reducer

          best = max_sea_reduction(left, targets, rest)
          targets.each_index do |i|
            next if left[i].zero? || (targets[i].hex_ids & reducer.hex_ids).empty?

            used = [left[i], reducer.amount].min
            left[i] -= used
            best = [best, used + max_sea_reduction(left, targets, rest)].max
            left[i] += used
          end
          best
        end

        # §11.3.4: a sea crossing is a route chain without track between the port nodes of two hexes. The port
        # access is checked, not ridden, so ports and zones serve any number of trains of one RR (§11.3.8).
        # The engine hook of Route#get_node_chains; the walked chains come first, a crossing last.
        def extra_node_chains(route, start_node, end_node)
          chain = sea_chain(start_node, end_node, route.corporation)
          chain ? [chain] : []
        end

        # The sea crossing chain between two nodes of different hexes, nil if their usable ports do not meet.
        def sea_chain(start_node, end_node, corporation)
          return if start_node.hex == end_node.hex

          crossing = sea_crossing(start_node, end_node, corporation)
          return unless crossing

          {
            nodes: [start_node, end_node],
            paths: [],
            hexes: [],
            id: [start_node.hex.id, "sea #{start_node.index}.#{end_node.index}", end_node.hex.id],
            sea: crossing,
          }
        end

        # A sea crossing in the route search's walk (#359): it stands in the walk's visited paths where a path would,
        # so the search can cut the walk into chains. nodes: [from, to], as a path's nodes.
        SeaJump = Struct.new(:chain) do
          def nodes
            chain[:nodes]
          end

          def terminal?
            false
          end

          # A jump comes from outside the hex, as a path over a hex side does (DoubleTown::Town#walk asks this:
          # a train arriving at one town of a double town has to visit the other first).
          def edges
            [:sea]
          end
        end

        # The nodes (city, town, red zone) of the hexes with a port; tiles change, so this is asked per search. A
        # smaller map (18OE UK-FR) lacks most of the hexes.
        def sea_port_nodes
          self.class::PORTS.keys.flat_map do |hex_id|
            tile = hex_by_id(hex_id)&.tile
            tile ? tile.cities + tile.towns + tile.offboards : []
          end
        end

        # The jumps of the route search from a node (#359): [chain, fewest units] for every crossing to a port node
        # of another hex. Fewest units: the zones less what port tokens at both ends could take off at most
        # (§11.3.5, A2 of #60); the search drops a jump whose fewest units no train of the RR can carry. A reducer
        # that is not a port token (#56, #73, #79, extra_sea_reducers) has to be added here once it exists.
        def sea_jumps(from_node, corporation, port_nodes = sea_port_nodes)
          return [] if port_accesses(from_node).empty?

          amount = phase.name.to_i >= 7 ? 2 : 1
          port_nodes.filter_map do |to_node|
            chain = sea_chain(from_node, to_node, corporation)
            next unless chain

            tokens = [from_node, to_node].count { |node| node.hex.tile.cities.any? { |c| c.tokened_by?(corporation) } }
            [chain, [chain[:sea][:zones] - (tokens * amount), 0].max]
          end
        end

        # §11.1.6, §11.2.1: what crossing open water adds to a tile or a token, per sea zone (#360, #61). Ferries:
        # #61. Port Authority (#56) takes two zones off; port tokens and Minor H do not.
        CROSS_WATER_TRACK_FEE = 10
        CROSS_WATER_TOKEN_FEE = 40

        # The fee for a tile in the hex: 0 over land, nil if the hex is not connected. With a tile (rotated as it is
        # to be laid), the zones to the sides it connects to (§11.1.6); without, the fewest zones to the hex (the
        # least a tile there can cost, for prices shown before a tile is chosen).
        def cross_water_track_fee(entity, hex, tile = nil)
          corporation = owning_corporation(entity)
          return 0 if corporation&.type == :national # §11.1.5: nationals lay track at no cost

          zones = graph_for_entity(corporation).water_zones_to_hex(corporation, hex, tile)
          zones && zones * self.class::CROSS_WATER_TRACK_FEE
        end

        def log_cross_water_fee(entity, fee, per_zone, what)
          zones = fee / per_zone
          @log << "#{entity.name} pays #{format_currency(fee)} for #{zones} sea zone#{zones == 1 ? '' : 's'} crossed " \
                  "to #{what}"
        end

        # The fee for a token in the city (§11.2.1): 0 over land, nil if the city is not connected.
        def cross_water_token_fee(entity, city)
          zones = token_graph_for_entity(entity).water_zones_to_node(entity, city)
          zones && zones * self.class::CROSS_WATER_TOKEN_FEE
        end

        # The sea zones of the node's usable ports (§11.3.4, §11.3.6).
        def usable_port_zones(node, corporation)
          port_accesses(node).select { |access| usable_port_access?(node, access, corporation) }.filter_map(&:zone).uniq
        end

        def fewest_sea_zones(from_zones, to_zones)
          from_zones.product(to_zones).filter_map { |a, b| sea_zone_distance(a, b) }.min
        end

        # The nodes a crossing of the RR's hypothetical train may end at: [node, its usable port zones].
        def sea_landings(corporation)
          sea_port_nodes.filter_map do |node|
            zones = usable_port_zones(node, corporation)
            [node, zones] unless zones.empty?
          end
        end

        # §11.1.3: the port arrows without track into a city or town that a crossing may end at, for a tile that
        # connects to the arrow: [hex, side, zone]. A private one only with a token of the RR in the city.
        def sea_arrows(corporation)
          self.class::PORTS.flat_map do |hex_id, exits|
            next [] unless (tile = hex_by_id(hex_id)&.tile)

            exits.filter_map do |exit, data|
              next if !data[:port] || exit == :offshore
              next if tile.city_towns.any? { |node| node.exits.include?(exit) }
              next if data[:port] != :public && tile.cities.none? { |city| city.tokened_by?(corporation) }

              [tile.hex, exit, port_sea_zone(hex_id, exit)]
            end
          end
        end

        # The most places of the city row a train has for sea units (as check_distance counts them): the bound of
        # the jumps.
        def sea_places(train)
          rows = train.distance
          return rows if rows.is_a?(Numeric)

          rows.select { |row| row['nodes'].include?('city') }.sum { |row| row['visit'] || row['pay'] }
        end

        # The crossing between usable ports of two nodes with the fewest sea zones (assumption A4 of #60). A port
        # token reduces by the end nodes, not by the port, so the fewest zones is also the cheapest crossing; a
        # reduction tied to a sea area (#56) has to weigh the candidates here instead.
        def sea_crossing(start_node, end_node, corporation)
          from = port_accesses(start_node).select { |access| usable_port_access?(start_node, access, corporation) }
          return if from.empty?

          to = port_accesses(end_node).select { |access| usable_port_access?(end_node, access, corporation) }
          from.product(to).map { |a, b| { from: a, to: b, zones: sea_zone_distance(a.zone, b.zone) } }
              .min_by { |crossing| crossing[:zones] }
        end

        def sea_crossings(route)
          (route.chains || []).select { |chain| chain[:sea] }
        end

        # §11.3.4: between two sea crossings the route crosses at least one land hex side (assumption A3 of #60):
        # a chain of track that leaves its hex. A ferry counts as land here (§11.3.7).
        def check_sea_crossings!(route)
          land = true
          route.chains.each do |chain|
            if chain[:sea]
              raise GameError, 'Two sea crossings need a land hex side between them' unless land

              land = false
            elsif chain[:paths].map(&:hex).uniq.size > 1
              land = true
            end
          end
        end

        # §12: "An Orient Express run may not consist entirely of sea crossings. Some land based track in addition
        # to the start and end cities must be utilized on the route." True for a route with a sea crossing whose track
        # lies only in the hexes of its first and last stop or on ferries and port stubs in sea hexes (#361).
        def sea_only_run?(route)
          return false if sea_crossings(route).empty?

          ends = [route.connection_data.first[:left].hex, route.connection_data.last[:right].hex]
          route.paths.none? { |path| path.hex.tile.color != :blue && !ends.include?(path.hex) }
        end

        # A route with sea crossings: each stretch of track between them is checked like a route of its own, and
        # a node where a crossing begins or ends inside the route may not be full of foreign tokens (§11.3.6).
        def check_sea_route_connected(route, corporation)
          route.connection_data.slice_when { |a, b| a[:chain][:sea] || b[:chain][:sea] }.each do |segments|
            next if segments.one? && segments[0][:chain][:sea]

            check_connected(LandStretch.new(segments), corporation)
          end
          route.connection_data.each_cons(2) do |before, after|
            next unless before[:chain][:sea] || after[:chain][:sea]
            raise GameError, 'Route is not connected' if before[:right].blocks?(corporation)
          end
        end

        # What check_connected sees of a stretch of track of a route between sea crossings (cf. Route#ordered_paths).
        LandStretch = Struct.new(:segments) do
          def chains
            []
          end

          def paths
            segments.flat_map { |segment| segment[:chain][:paths] }
          end

          def ordered_paths
            segments.flat_map do |segment|
              paths = segment[:chain][:paths]
              next [] if paths.empty?

              paths[0].nodes.include?(segment[:left]) ? paths : paths.reverse
            end
          end
        end

        # Assumption A1 of #60: units take places of the row of cities (the row that holds 'city'), for visiting
        # and for paying. The rows themselves are not changed.
        def distance_rows_after_sea(rows, units)
          rows.map do |row|
            next row unless row['nodes'].include?('city')

            row.merge('pay' => [row['pay'] - units, 0].max, 'visit' => [(row['visit'] || row['pay']) - units, 0].max)
          end
        end

        def ferry_line?(path)
          path.color.to_s.casecmp?(self.class::FERRY_COLOR)
        end

        def ferry_components
          build_ferry_components unless @ferry_components
          @ferry_components
        end

        # The component a blue ferry path belongs to, nil for any other path.
        def ferry_component(path)
          build_ferry_components unless @ferry_component_by_path
          @ferry_component_by_path[path]
        end

        private

        # Blue ferry lines lie in sea hexes, where no tile is ever laid, so the components are built once.
        def build_ferry_components
          @ferry_component_by_path = {}.compare_by_identity
          @ferry_components = []
          hexes.each do |hex|
            hex.tile.paths.each do |path|
              next if !ferry_line?(path) || @ferry_component_by_path[path]

              @ferry_components << collect_ferry_component(path)
            end
          end
          ferry_ends.each do |hex_id, exit, distances|
            component = ferry_end_paths(hex_id, exit).filter_map { |path| @ferry_component_by_path[path] }.first
            next unless component

            component.ends << [hex_id, exit]
            component.distances |= distances
          end
        end

        def collect_ferry_component(start)
          component = FerryComponent.new([], [], [])
          queue = [start]
          @ferry_component_by_path[start] = component
          until queue.empty?
            path = queue.shift
            component.hex_ids << path.hex.id unless component.hex_ids.include?(path.hex.id)
            joined_ferry_lines(path).each do |other|
              next if @ferry_component_by_path[other]

              @ferry_component_by_path[other] = component
              queue << other
            end
          end
          component
        end

        # Blue paths of the same hex sharing a side or a node (town, junction), and blue paths of a
        # neighbouring hex continuing over the shared side.
        def joined_ferry_lines(path)
          same_hex = path.hex.tile.paths.select do |other|
            ferry_line?(other) && (other.exits.intersect?(path.exits) || other.nodes.intersect?(path.nodes))
          end
          same_hex + path.exits.flat_map { |exit| ferry_lines_at(path.hex.all_neighbors[exit], Hex.invert(exit)) }
        end

        def ferry_lines_at(hex, exit)
          return [] unless hex

          hex.tile.paths.select { |path| ferry_line?(path) && path.exits.include?(exit) }
        end

        # [hex_id, exit, distances] for every ferry end of PORTS.
        def ferry_ends
          self.class::PORTS.flat_map do |hex_id, exits|
            exits.filter_map do |exit, data|
              [hex_id, exit, data[:ferries].map { |ferry| ferry[:distance] }] if data[:ferries]
            end
          end
        end

        # The blue paths a ferry end touches: over its hex side, or anywhere in the offshore port hex.
        def ferry_end_paths(hex_id, exit)
          if exit == :offshore
            hex_by_id(self.class::PORTS[hex_id][:offshore][:hex]).tile.paths.select { |path| ferry_line?(path) }
          else
            ferry_lines_at(hex_by_id(hex_id).all_neighbors[exit], Hex.invert(exit))
          end
        end
      end
    end
  end
end
