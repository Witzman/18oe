# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # Ports and ferries as data (§11.3.4, §11.3.6, §11.3.7), read from Map::PORTS and the blue ferry lines
      # of the map. Queries only: no step and no route uses them yet (sea crossings build on them, #60).
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
