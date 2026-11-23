# frozen_string_literal: true

require "engine"

module Oe
  # The per-train detail of a corporation's last run for the view (#119). Chris' Engine::OperatingInfo keeps only
  # the saved connection hexes, halts and node signatures, so the run is rebuilt from its run_routes action the
  # way his replay builds it (Action::RunRoutes.h_to_args): the revenue of each train is the one recorded then,
  # the paths come from the saved hexes on today's board. A train whose run cannot be rebuilt (an upgrade since
  # broke the saved hexes) shows its recorded revenue without paths.
  module RunDetail
    module_function

    # [{train:, name:, revenue:, hexes:, segments:, stops:, distance_str:, sea:, ferries:}, ...] or nil.
    def of(game, corporation)
      action = game.raw_actions.reverse_each.find { |a| a["type"] == "run_routes" && a["entity"] == corporation.id }
      return unless action

      routes = Engine::Action::RunRoutes.h_to_args(action, game)[:routes]
      routes.each { |route| route.routes = routes }
      routes.map { |route| detail(game, route) }
    end

    def detail(game, route)
      sea = sea_detail(game, route)
      {
        train: route.train.id,
        name: route.train.name,
        revenue: route.revenue,
        # a sea chain's id ("crossing", hex, exit, hex, exit) sits between the land hexes: keep the hexes of the board
        hexes: guarded([]) { route.connection_hex_ids.map(&:to_s).select { |id| game.hex_by_id(id) } },
        segments: guarded([]) { segments(route) },
        stops: guarded([]) { stops(route) },
        distance_str: guarded(nil) { route.distance_str },
        sea: sea[:sea],
        ferries: sea[:ferries],
      }
    end

    # The paths in order, as Route#ordered_paths. A chain without track between two nodes (an 18OE sea crossing)
    # stands in with its two end hexes, without exits, so the segments keep following the run's hexes.
    def segments(route)
      route.connection_data.flat_map do |c|
        paths = c[:chain][:paths]
        if paths.empty?
          next [] if c[:left] == c[:right]

          next [c[:left], c[:right]].map { |node| { hex: node.hex.id, exits: [], nodes: [node.index] } }
        end

        paths = paths.reverse unless paths[0].nodes.include?(c[:left])
        paths.map { |path| { hex: path.hex.id, exits: path.exits, nodes: path.nodes.map(&:index) } }
      end
    end

    def stops(route)
      route.visited_stops.map do |stop|
        { hex: stop.hex.id, index: stop.index, revenue: stop.route_revenue(route.phase, route.train) }
      end
    end

    # The sea stretches the run pays for: the crossings (water zones) and the ferries (units). The per-stretch
    # reductions of a port authority or Minor H are not split here; `distance_str` has the total.
    def sea_detail(game, route)
      legs = game.sea_legs(route)
      crossings = legs.grep(Engine::Game::G18OE::SeaCrossing)
      ferries = legs.grep(Engine::Game::G18OE::FerryLeg)
      {
        sea: crossings.map do |leg|
          { from: leg.from[0], from_exit: leg.from[1], to: leg.to[0], to_exit: leg.to[1],
            zones: leg.units, counted: leg.units, reductions: [] }
        end,
        ferries: ferries.map { |leg| { ferry: leg.nodes.map { |node| node.hex.id }.join("-"), distance: leg.units, counted: leg.units } },
      }
    rescue StandardError
      { sea: [], ferries: [] }
    end

    def guarded(fallback)
      yield
    rescue StandardError
      fallback
    end
  end
end
