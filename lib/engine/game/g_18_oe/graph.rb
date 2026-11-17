# frozen_string_literal: true

require_relative '../../graph'

module Engine
  module Game
    module G18OE
      class Graph < Engine::Graph
        def walk_token(node, skip_paths:, corporation:, **opts)
          # §14.9: the paths of hexes marked by a Brandt & Brandau token are closed to other players' RRs
          # (the route search passes its own skip_paths, so the game's graph_skip_paths is merged here)
          if (blocked = @game.graph_skip_paths(corporation))
            skip_paths = (skip_paths || {}).merge(blocked)
          end
          return super unless @game.wcf_placeholder

          lille = @game.lille_city
          walker = proc do |path, visited_paths, visited|
            result = yield path, visited_paths, visited
            if result != :abort && path.nodes.include?(lille) && !visited[lille] && @game.wcf_restricted?(corporation)
              land_paths = @game.wcf_path?(path) ? [] : lille.paths.reject { |other| @game.wcf_path?(other) }
              lille.walk(**opts.merge(visited: visited, visited_paths: visited_paths, corporation: corporation,
                                      skip_paths: (skip_paths || {}).merge(land_paths.to_h { |other| [other, true] }),
                                      counter: Hash.new(0)), &walker)
            end
            result
          end
          super(node, skip_paths: skip_paths, corporation: corporation, **opts, &walker)
        end
      end
    end
  end
end
