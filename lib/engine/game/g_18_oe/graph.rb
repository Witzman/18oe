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
