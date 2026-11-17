# frozen_string_literal: true

module Engine
  # Information about an entities operating round
  class OperatingInfo
    attr_reader :routes, :halts, :nodes, :dividend, :revenue, :dividend_kind, :revenues, :segments, :stops
    attr_accessor :laid_hexes

    def initialize(runs, dividend, revenue, laid_hexes, dividend_kind: nil)
      # Convert the route into connection hexes as upgrades may break the representation
      @routes = runs.to_h { |run| [run.train, run.connection_hexes] }
      @halts = runs.to_h { |run| [run.train, run.halts] }
      @nodes = runs.to_h { |run| [run.train, run.node_signatures] }
      # Per-train detail for the view (#119): revenue, the paths driven in order
      # (hex id and exit edges) and the stops with their revenue. Captured here,
      # while the board still matches the run, because a later upgrade changes it.
      @revenues = runs.to_h { |run| [run.train, run.revenue] }
      @segments = runs.to_h { |run| [run.train, run_segments(run)] }
      @stops = runs.to_h { |run| [run.train, run_stops(run)] }
      @revenue = revenue
      @dividend = dividend
      @laid_hexes = laid_hexes
      @dividend_kind = dividend_kind || (dividend.is_a?(Engine::Action::Dividend) ? dividend.kind : 'withhold')
    end

    private

    # The paths in order, as Route#ordered_paths. A chain without track between two nodes (a game's
    # extra_node_chains, e.g. an 18OE sea crossing, #436) stands in with its two end hexes, without exits, so the
    # segments keep following the run's hexes.
    def run_segments(run)
      run.connection_data.flat_map do |c|
        paths = c[:chain][:paths]
        if paths.empty?
          next [] if c[:left] == c[:right]

          next [c[:left], c[:right]].map { |node| { hex: node.hex.id, exits: [], nodes: [node.index] } }
        end

        paths = paths.reverse unless paths[0].nodes.include?(c[:left])
        paths.map { |path| { hex: path.hex.id, exits: path.exits, nodes: path.nodes.map(&:index) } }
      end
    rescue StandardError
      []
    end

    def run_stops(run)
      run.visited_stops.map do |stop|
        { hex: stop.hex.id, index: stop.index, revenue: stop.route_revenue(run.phase, run.train) }
      end
    rescue StandardError
      []
    end
  end
end
