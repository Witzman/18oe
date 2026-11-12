# frozen_string_literal: true

require 'engine'

module Oe
  # Pure-Ruby copy of Engine::AutoRouter's path search (`path`, `real_revenue`
  # and the bitfield helpers).
  #
  # Engine::AutoRouter cannot be loaded under MRI: its route *combiner* is a
  # JavaScript class embedded in `%x{...}` for Opal, which MRI would run as a
  # shell command when the file is required. Only the combiner is Opal-only;
  # the path search is plain Ruby, kept here as in engine/auto_router.rb.
  class RouteSearch
    attr_accessor :running

    def initialize(game, flash = nil)
      @game = game
      @train_autoroute_group = @game.class::TRAIN_AUTOROUTE_GROUPS
      @next_hexside_bit = 0
      @flash = flash
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

    def path(trains, corporation, **opts)
      static = opts[:routes] || []
      path_timeout = opts[:path_timeout] || 30
      route_limit = opts[:route_limit] || 10_000

      connections = {}

      graph = @game.graph_for_entity(corporation)
      nodes = graph.connected_nodes(corporation).keys.sort_by do |node|
        revenue = trains
          .map { |train| node.route_revenue(@game.phase, train) }
          .max
        [
          node.tokened_by?(corporation) ? 0 : 1,
          node.offboard? ? 0 : 1,
          -revenue,
        ]
      end

      path_walk_timed_out = false
      now = Time.now

      skip_paths = if @train_autoroute_group.nil?
                     static.flat_map(&:paths).to_h { |path| [path, true] }
                   elsif @train_autoroute_group == :each_train_separate
                     # all trains have their own autoroute group so it's not possible to fill skip_paths
                     {}
                   else # rubocop:disable Lint/DuplicateBranch
                     # NOTE: there is room for an optimization here. In the case of TRAIN_AUTOROUTE_GROUP being an array,
                     # we need to compare the train types that are prefilled and the train types that will be searched and
                     # if there is overlap and all the trains that are being searched can't visit the path it can be in skip_path
                     {}
                   end

      # if only routing for subset of trains, omit the trains we won't assemble routes for
      skip_trains = static.flat_map(&:train).to_a
      trains -= skip_trains

      train_routes = Hash.new { |h, k| h[k] = [] }    # map of train to route list
      hexside_bits = Hash.new { |h, k| h[k] = 0 }     # map of hexside_id to bit number
      @next_hexside_bit = 0

      nodes.each do |node|
        if Time.now - now > path_timeout
          ::LOGGER.debug('Path timeout reached')
          path_walk_timed_out = true
          break
        else
          ::LOGGER.debug { "Path search: #{nodes.index(node)} / #{nodes.size} - paths starting from #{node.hex.name}" }
        end

        walk_corporation = graph.no_blocking? ? nil : corporation
        graph.walk_token(node, corporation: walk_corporation, skip_paths: skip_paths) do |_, vp|
          paths = vp.keys
          chains = []
          chain = []
          left = nil
          right = nil
          last_left = nil
          last_right = nil

          complete = lambda do
            chains << { nodes: [left, right], paths: chain, hexes: chain.map(&:hex) }
            last_left = left
            last_right = right
            left, right = nil
            chain = []
          end

          assign = lambda do |a, b|
            if a && b
              if a == last_left || b == last_right
                left = b
                right = a
              else
                left = a
                right = b
              end
              complete.call
            elsif !left
              left = a || b
            elsif !right
              right = a || b
              complete.call
            end
          end

          paths.each do |path|
            chain << path
            a, b = path.nodes

            assign.call(a, b) if a || b
          end

          # a 1-city Local train will have no chains but will have a left; route.revenue will reject if not valid for game
          if chains.empty?
            next unless left

            chains << { nodes: [left, nil], paths: [] }

            # use the Local train's 1 city instead of any paths as their key;
            # only 1 train can visit each city, but we want Locals to be able to
            # visit multiple different cities if a corporation has more than one
            # of them
            id = [left]
          else
            id = chains.flat_map { |c| c[:paths] }.sort!
          end

          next if connections[id]

          connections[id] = chains.map do |c|
            { left: c[:nodes][0], right: c[:nodes][1], chain: c }
          end

          connection = connections[id]

          # each train has opportunity to vote to abort a branch of this node's path-walk tree
          path_abort = trains.to_h { |train| [train, true] }

          # build a test route for each train, use route.revenue to check for errors, keep the good ones
          trains.each  do |train|
            route = Engine::Route.new(
              @game,
              @game.phase,
              train,
              # we have to clone to prevent multiple routes having the same connection array.
              # If we don't clone, then later route.touch_node calls will affect all routes with
              # the same connection array
              connection_data: connection.clone,
              bitfield: bitfield_from_connection(connection, hexside_bits),
            )
            route.routes = [route]
            # defer route combination checks until we have the full combination of routes to check
            route.revenue(suppress_check_route_combination: true)
            train_routes[train] << route
          rescue Engine::RouteTooLong
            # ignore for this train, and abort walking this path if ignored for all trains
            path_abort.delete(train)
          rescue Engine::ReusesCity
            path_abort.clear
          rescue Engine::NoToken, Engine::RouteTooShort, Engine::GameError # rubocop:disable Lint/SuppressedException
          end

          next :abort if path_abort.empty?
        end
      end

      # Check that there are no duplicate hexside bits (algorithm error)
      ::LOGGER.debug do
        "Evaluated #{connections.size} paths, found #{@next_hexside_bit} unique hexsides, and found valid routes "\
          "#{train_routes.map { |k, v| k.name + ':' + v.size.to_s }.join(', ')} in: #{Time.now - now}"
      end

      static.each do |route|
        # recompute bitfields of passed-in routes since the bits may have changed across auto-router runs
        route.bitfield = bitfield_from_connection(route.connection_data, hexside_bits)
        train_routes[route.train] = [route] # force this train's route to be the passed-in one
      end

      train_routes.each do |train, routes|
        train_routes[train] = routes.sort_by(&:revenue).reverse.take(route_limit)
      end

      [train_routes, path_walk_timed_out]
    end

    # inputs:
    #   connection is a route's connection_data
    #   hexside_bits is a map of hexside_id to bit number
    # returns:
    #   the bitfield (array of ints) representing all hexsides in the connection path
    # updates:
    #   new hexsides are added to hexside_bits
    def bitfield_from_connection(connection, hexside_bits)
      bitfield = [0]
      connection.each do |conn|
        paths = conn[:chain][:paths]
        if paths.size == 1 # special case for tiny intra-tile path like in 18NewEngland (issue #6890)
          hexside_left = paths[0].nodes[0].id
          check_edge_and_set(bitfield, hexside_left, hexside_bits)
          if paths[0].nodes.size > 1 # local trains may not have a second node
            hexside_right = paths[0].nodes[1].id
            check_edge_and_set(bitfield, hexside_right, hexside_bits)
          end
        else
          (paths.size - 1).times do |index|
            # hand-optimized ruby gives faster opal code
            node1 = paths[index]
            node2 = paths[index + 1]
            case node1.edges.size
            when 1
              # node1 has 1 edge, connect it to first edge of node2
              hexside_left = node1.edges[0].id
              hexside_right = node2.edges[0].id
              check_and_set(bitfield, hexside_left, hexside_right, hexside_bits)
            when 2
              # node1 has 2 edges, connect them as well as 2nd edge to first node2 edge
              hexside_left = node1.edges[0].id
              hexside_right = node1.edges[1].id
              check_and_set(bitfield, hexside_left, hexside_right, hexside_bits)
              hexside_left = hexside_right
              hexside_right  = node2.edges[0].id
              check_and_set(bitfield, hexside_left, hexside_right, hexside_bits)
            else
              ::LOGGER.debug do
                "  ERROR: auto-router found unexpected number of path node edges #{node1.edges.size}. "\
                  'Route combos may be be incorrect'
              end
            end
          end
        end
      end
      bitfield
    end

    def check_and_set(bitfield, hexside_left, hexside_right, hexside_bits)
      check_edge_and_set(bitfield, hexside_left, hexside_bits)
      check_edge_and_set(bitfield, hexside_right, hexside_bits)
    end

    def check_edge_and_set(bitfield, hexside_edge, hexside_bits)
      if hexside_bits.include?(hexside_edge)
        set_bit(bitfield, hexside_bits[hexside_edge])
      else
        hexside_bits[hexside_edge] = @next_hexside_bit
        set_bit(bitfield, @next_hexside_bit)
        @next_hexside_bit += 1
      end
    end

    # bitfield is an array of integers, can be expanded by this call if necessary
    # bit is a bit number, 0 is lowest bit, 32 will jump to the next int in the array, and so on
    def set_bit(bitfield, bit)
      entry = (bit / 32).to_i
      mask = 1 << (bit & 31)
      add_count = entry + 1 - bitfield.size
      while add_count.positive?
        bitfield << 0
        add_count -= 1
      end
      bitfield[entry] |= mask
    end
  end
end
