# frozen_string_literal: true

require 'engine'
require 'engine/auto_router'

module Oe
  # Route candidates and a greedy combination on top of the core Engine::AutoRouter#path (its route combiner
  # is a JavaScript class in `%x{...}`, Opal-only, and is never called under MRI).
  class RouteSearch
    def initialize(game, flash = nil)
      @game = game
      @flash = flash
    end

    # Oe extension: the candidate routes per train of `corporation`, searched as the RoutePicker does.
    def train_routes(corporation)
      path(@game.route_trains(corporation).sort_by(&:price), corporation).first
    end

    # Oe extension (the RoutePicker's combination, moved here for #512): per train in the order of
    # `train_routes` (a hash or [train, candidates] pairs), the best candidate that fits the routes chosen so
    # far (greedy; AutoRouter's combiner is Opal-only). `chosen` holds routes already fixed; their trains pick
    # nothing more. The routes come back settled.
    def pick(train_routes, chosen = [])
      chosen = chosen.dup
      train_routes.each do |train, candidates|
        next if chosen.any? { |route| route.train == train }

        route = candidates.find { |candidate| compatible?(chosen, candidate) }
        chosen << route if route
      end
      settle(chosen)
      chosen
    end

    # Oe extension (#512, §12.1): the Orient Express routes a train made by combining `trains` could run.
    # Read-only: the trial train is never added to the depot or the corporation. It is built as the engine's
    # step builds the combined train (G18OE::Step::Route#combined_train!, private and adding the train to the
    # depot): the summed cities and towns, its town row unlimited. The search is the picker's.
    def orient_express_routes(corporation, trains)
      trial = combined_trial_train(corporation, trains)
      routes, = path([trial], corporation)
      routes[trial].select { |route| @game.orient_express_run?(route) }
    end

    def combined_trial_train(corporation, trains)
      cities, towns = trains.map { |t| @game.distance(t) }.transpose.map(&:sum)
      distance = [
        { 'nodes' => ['town'], 'pay' => towns, 'visit' => 99 },
        { 'nodes' => %w[city offboard town], 'pay' => cities, 'visit' => cities },
      ]
      Engine::Train.new(name: "#{cities}+#{towns}", distance: distance, price: 0).tap { |t| t.owner = corporation }
    end

    # Every set of two or more of `candidates`, one per multiset of train names, smallest first.
    def combinations(candidates)
      sorted = candidates.sort_by { |t| [t.name, t.id] }
      (2..sorted.size).flat_map { |n| sorted.combination(n).to_a }.uniq { |trains| trains.map(&:name) }
    end

    # Each route validates itself against the other chosen routes, so the
    # shared `routes` list must be the final one before the action is built.
    def settle(chosen)
      chosen.each do |route|
        route.clear_cache!(only_routes: true)
        route.routes = chosen
      end
    end

    def compatible?(chosen, candidate)
      trial = chosen + [candidate]
      trial.each { |r| r.routes = trial }
      real_revenue(trial) >= 0 && candidate.revenue.positive?
    rescue Engine::GameError
      false
    ensure
      settle(chosen)
    end

    def real_revenue(routes)
      routes.each do |route|
        route.clear_cache!(only_routes: true)
        route.routes = routes
        route.revenue
      end
      @game.routes_revenue(routes)
    rescue Engine::GameError
      -1
    end

    # The candidate routes per train: the core AutoRouter's own path search (#563: no copy of it any more;
    # Chris' graph walk hands the sea crossings as chains, so 18OE needs no extra pass). Returns
    # [train_routes, timed_out] like AutoRouter#path. Only its combiner is Opal-only, hence `pick` above.
    def path(trains, corporation, **opts)
      Engine::AutoRouter.new(@game, @flash).path(trains, corporation, **opts.slice(:routes, :path_timeout, :route_limit))
    end
  end
end
