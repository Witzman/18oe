# frozen_string_literal: true

require_relative '../../auto_router'

module Engine
  module Game
    module G18OE
      # RB 12.2: "A RR is not obligated to run the Orient Express on the first occasion it is able to do so, unless such
      # a route is part of the 'best possible routes' for all trains on the RR. (Ties do not count as best possible.)"
      # Read as the routes with the highest total revenue over all trains of the RR, including trains the RR may still
      # combine (RB 12.1). Only a major without the Orient Express marker whose network reaches both ends is checked.
      # The candidate routes come from the core Engine::AutoRouter#path; its route combiner is Opal-only (a JavaScript
      # class), so the routes are combined greedily here, best candidate first, as the RoutePicker does.
      module OrientExpressDuty
        ORIENT_EXPRESS_REQUIRED = 'Orient Express is required: the best routes for all trains include an '\
                                  'Orient Express run (RB 12.2).'
        # Cap on the path-walk callbacks of every search of this check (AutoRouter#path walk_limit, patch 0019): the answer
        # does not depend on the wall clock. One source for the engine and for Oe::RouteSearch.
        WALK_LIMIT = 400_000

        # The best solution found with an Orient Express run, {revenue:, routes:, combine:}, when `routes` (the submitted
        # ones) leave out an Orient Express run and earn less, and the solution earns strictly more than the best found
        # without one; nil otherwise. `combine` is the set of trains to combine first (then `routes` is nil: the routes of
        # a combined train exist only after the combination), else `routes` are routes of the trains as they stand.
        # `train_routes` ({train => candidates}) may be handed in when the candidates are known already.
        def orient_express_required(corporation, routes, train_routes = nil)
          return unless orient_express_duty?(corporation)

          best = orient_express_best(corporation, train_routes) if train_routes
          return if orient_express_route(routes)

          best ||= orient_express_best(corporation)
          return if !best || routes_revenue(routes) >= best[:revenue]

          duty_settle(best[:routes]) if best[:routes]
          best
        end

        def orient_express_duty?(corporation)
          corporation&.corporation? && corporation.type == :major && !orient_express_marker?(corporation) &&
            orient_express_reachable?(corporation)
        end

        # The Orient Express routes a train made by combining `trains` could run. Read-only: the trial train is never
        # added to the depot or the corporation. The search walks the whole network (5-8 s on a late map) and is asked
        # again and again in one state (the duty check, the combinations, the wrapper's reach for the same summed
        # trains), so the routes are kept for the state: same RR, same summed reach, same round and last action.
        def orient_express_trial_routes(corporation, trains)
          key = orient_express_best_key(corporation)
          @orient_express_trial = [key, {}] unless @orient_express_trial&.first == key
          cities, towns = trains.map { |t| distance(t) }.transpose.map(&:sum)
          @orient_express_trial[1][[cities, towns]] ||= begin
            trial = Engine::Train.new(
              name: "#{cities}+#{towns}",
              price: 0,
              distance: [
                { 'nodes' => ['town'], 'pay' => towns, 'visit' => 99 },
                { 'nodes' => %w[city offboard town], 'pay' => cities, 'visit' => cities },
              ],
            ).tap { |t| t.owner = corporation }
            found, = Engine::AutoRouter.new(self).path([trial], corporation, walk_limit: WALK_LIMIT)
            found[trial].select { |route| orient_express_run?(route) }
          end
        end

        # The step help names the duty only once the routes have been searched in this state, so showing the prompt
        # never starts a search of its own.
        def orient_express_required_known?(corporation)
          @orient_express_best&.first == orient_express_best_key(corporation) && !@orient_express_best[1].nil?
        end

        # RB 12: "An Orient Express run may not consist entirely of sea crossings. Some land based track in addition to the
        # start and end cities must be utilized on the route." True for a route with a sea crossing whose track lies only
        # in the hexes of its first and last stop or on ferries and port stubs in sea hexes. Asked from the connection
        # data alone (Route#shared_cache is the auto-router's, not every caller's).
        def sea_only_run?(route)
          return false if connection_sea_legs(route.connection_data).empty?

          ends = [route.connection_data.first[:left].hex, route.connection_data.last[:right].hex]
          route.paths.none? { |path| path.hex.tile.color != :blue && !ends.include?(path.hex) }
        end

        private

        def orient_express_best(corporation, train_routes = nil)
          key = orient_express_best_key(corporation)
          return @orient_express_best[1] if !train_routes && @orient_express_best&.first == key

          result = orient_express_compare(corporation, train_routes || duty_train_routes(corporation))
          @orient_express_best = [key, result]
          result
        end

        def orient_express_best_key(corporation)
          [corporation, @round, @last_processed_action]
        end

        def orient_express_compare(corporation, train_routes)
          without = duty_pick(train_routes.transform_values { |routes| routes.reject { |r| orient_express_run?(r) } })
          without_revenue = duty_revenue(without)
          with = train_routes.filter_map { |_train, routes| routes.find { |r| orient_express_run?(r) } }
                             .map { |route| duty_pick(train_routes, [route]) }
                             .map { |picked| { revenue: duty_revenue(picked), routes: picked } }
          with.concat(orient_express_combinations(corporation, train_routes))
          best = with.max_by { |solution| solution[:revenue] }
          best if best && best[:revenue] > without_revenue
        end

        # RB 12.1: the solutions with two or more of the RR's non-permanent trains combined into one that runs an Orient
        # Express route. Trains of one name are interchangeable, so each multiset of names is tried once.
        def orient_express_combinations(corporation, train_routes)
          candidates = double_head_candidates(corporation)
          return [] if candidates.size < 2

          widest = orient_express_trial_routes(corporation, candidates)
          return [] if widest.empty?

          need = widest.map { |route| route.visited_stops.count { |stop| !stop.town? } }.min
          duty_combinations(candidates).filter_map do |trains|
            next if trains.sum { |train| distance(train).first } < need

            routes = orient_express_trial_routes(corporation, trains)
            next if routes.empty?

            others = train_routes.reject { |train, _| trains.include?(train) }
            picked = duty_pick(others, [routes.first])
            revenue = duty_revenue(picked)
            { revenue: revenue, routes: nil, combine: trains } unless revenue.negative?
          end
        end

        def duty_train_routes(corporation)
          trains = route_trains(corporation).sort_by(&:price)
          Engine::AutoRouter.new(self).path(trains, corporation, walk_limit: WALK_LIMIT).first
        end

        def duty_combinations(candidates)
          sorted = candidates.sort_by { |t| [t.name, t.id] }
          (2..sorted.size).flat_map { |n| sorted.combination(n).to_a }.uniq { |trains| trains.map(&:name) }
        end

        # Per train in the order given, the best candidate that fits the routes chosen so far (greedy). `chosen` holds
        # routes already fixed; their trains pick nothing more.
        def duty_pick(train_routes, chosen = [])
          chosen = chosen.dup
          train_routes.each do |train, candidates|
            next if chosen.any? { |route| route.train == train }

            route = candidates.find { |candidate| duty_compatible?(chosen, candidate) }
            chosen << route if route
          end
          duty_settle(chosen)
          chosen
        end

        def duty_settle(chosen)
          chosen.each do |route|
            route.clear_cache!(only_routes: true)
            route.routes = chosen
          end
        end

        def duty_compatible?(chosen, candidate)
          trial = chosen + [candidate]
          trial.each { |r| r.routes = trial }
          duty_revenue(trial) >= 0 && candidate.revenue.positive?
        rescue GameError
          false
        ensure
          duty_settle(chosen)
        end

        def duty_revenue(routes)
          routes.each do |route|
            route.clear_cache!(only_routes: true)
            route.routes = routes
            route.revenue
          end
          routes_revenue(routes)
        rescue GameError
          -1
        end
      end
    end
  end
end
