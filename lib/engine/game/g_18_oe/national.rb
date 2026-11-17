# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # §11.3.10: a national does not run routes. It has a virtual token in every city of its home track
      # rights zone and counts the zone's places up to the capacity of its trains. Small upstream-shaped
      # extension (workshop #64): the Dividend step asks national_run for the revenue instead of the routes.
      module National
        NATIONAL_FILL_CITY = 60
        NATIONAL_FILL_TOWN = 10
        PULLMAN_PER_LEVEL = 10

        # Step 1: the cities of the D trains (doubled), of the other trains, and the towns of all trains.
        Capacity = Struct.new(:doubled, :cities, :towns)

        # What a national counts: the values of the linked places it counts (doubled: of the D trains),
        # the capacity unlinked places take at £0, the capacity left over (£60 a city, £10 a town) and
        # the Pullman. The places themselves (stops) are kept for the log.
        Run = Struct.new(:doubled, :cities, :towns, :zero_cities, :zero_towns, :filled_cities, :filled_towns,
                         :pullman, keyword_init: true) do
          def revenue
            (2 * doubled.sum) + cities.sum + towns.sum + (filled_cities * NATIONAL_FILL_CITY) +
              (filled_towns * NATIONAL_FILL_TOWN) + pullman
          end
        end

        def national_capacity(corporation)
          corporation.trains.each_with_object(Capacity.new(0, 0, 0)) do |train, capacity|
            cities, towns = distance(train)
            if (train.multiplier || 1) > 1
              capacity.doubled += cities
            else
              capacity.cities += cities
            end
            capacity.towns += towns
          end
        end

        # §11.3.10: "A national automatically attaches a Pullman to its highest level train"; a Pullman
        # adds £10 per level (§11.3.9). The level is the card's: 4D is level 7, 5D level 8 (§11.3.2).
        def national_pullman_level(corporation)
          corporation.trains.map { |train| train.sym.to_i }.max || 0
        end

        # Steps 2 to 4 with the values of the linked places and the number of unlinked ones. The president's
        # choices (which places, which are doubled) are made for the most revenue: the most valuable linked
        # places first, the best of them on the D trains. Step 2 counts linked places before the unlinked
        # ones take capacity (PB 4.6 counts a £30 city before filling at £60).
        # ASSUMPTION (workshop #64): spare capacity is £60 a city also on a D train (step 4 names no
        # doubling), and towns count only on town capacity (step 2 names both capacities apart).
        def count_national_revenue(capacity, linked_cities:, unlinked_cities:, linked_towns:, unlinked_towns:, pullman_level:)
          ranked = linked_cities.sort.reverse
          doubled = ranked.take(capacity.doubled)
          cities = ranked.drop(capacity.doubled).take(capacity.cities)
          towns = linked_towns.sort.reverse.take(capacity.towns)
          city_room = capacity.doubled + capacity.cities - doubled.size - cities.size
          town_room = capacity.towns - towns.size
          zero_cities = [unlinked_cities, city_room].min
          zero_towns = [unlinked_towns, town_room].min
          Run.new(doubled: doubled, cities: cities, towns: towns, zero_cities: zero_cities, zero_towns: zero_towns,
                  filled_cities: city_room - zero_cities, filled_towns: town_room - zero_towns,
                  pullman: pullman_level * PULLMAN_PER_LEVEL)
        end

        # The run of a national now: its zone's places, linked or not, counted with its trains.
        def national_run(corporation)
          cities, towns = national_zone_stops(corporation).partition { |stop| !stop.town? }
          linked_cities, unlinked_cities = cities.partition { |stop| national_linked?(stop, corporation) }
          linked_towns, unlinked_towns = towns.partition { |stop| national_linked?(stop, corporation) }
          count_national_revenue(
            national_capacity(corporation),
            linked_cities: linked_cities.map { |stop| national_stop_value(stop) },
            unlinked_cities: unlinked_cities.size,
            linked_towns: linked_towns.map { |stop| national_stop_value(stop) },
            unlinked_towns: unlinked_towns.size,
            pullman_level: national_pullman_level(corporation),
          )
        end

        def national_revenue(corporation)
          corporation.trains.empty? ? 0 : national_run(corporation).revenue
        end

        def national_run_str(corporation)
          run = national_run(corporation)
          parts = []
          parts << "#{run.doubled.size} doubled" unless run.doubled.empty?
          parts << "#{run.cities.size} cities" unless run.cities.empty?
          parts << "#{run.towns.size} towns" unless run.towns.empty?
          parts << "#{run.zero_cities + run.zero_towns} unlinked at #{format_currency(0)}" if (run.zero_cities + run.zero_towns).positive?
          parts << "#{run.filled_cities} x #{format_currency(NATIONAL_FILL_CITY)}" if run.filled_cities.positive?
          parts << "#{run.filled_towns} x #{format_currency(NATIONAL_FILL_TOWN)}" if run.filled_towns.positive?
          parts << "Pullman #{format_currency(run.pullman)}" if run.pullman.positive?
          parts.join(', ')
        end

        # The cities, red zones and towns of the home track rights zone (§11.3.10). The zone is the
        # hex list of the national's region (CITY_NATIONAL_ZONE decides the cities on a border hex).
        # ASSUMPTION (workshop #64): the charter's list of red zones is the region's hex list.
        def national_zone_stops(corporation)
          zone = entity_track_rights_zone(corporation)
          return [] unless zone

          hexes.select { |hex| region_for_hex(hex) == zone }.flat_map { |hex| hex.tile.cities + hex.tile.offboards + hex.tile.towns }
        end

        # ANNAHME A (workshop #64, open owner question): the virtual tokens of §11.3.10 also count as the
        # token a laid tile must connect to (§11.1), so a national lays track from every city of its home
        # zone. Not built: B (nationals lay no track), C (anywhere in the zone without a connection).
        # Upstream hook of Engine::Graph#compute.
        def for_graph_city_tokened_by?(city, corporation, graph)
          return super unless corporation&.corporation? && corporation.type == :national

          zone = entity_track_rights_zone(corporation)
          !zone.nil? && region_for_hex(city.hex) == zone
        end

        # A city's or red zone's value in the current phase; a town's printed on its tile.
        def national_stop_value(stop)
          stop.route_base_revenue(@phase, NationalTrain)
        end

        # What route_base_revenue reads of a train: only its name (no diesel trains in 18OE).
        NationalTrain = Struct.new(:name).new('national')

        # §11.3.10: a place is linked if it can trace a route to any other city, red zone or town, inside or
        # outside the zone. Ferries count (they are track), sea crossings do not (they are not), and track
        # marked by a Brandt & Brandau token does not count for the national (§14.9). Virtual tokens: no city
        # blocks the national, and the first place reached ends the search. A red zone that only the sea
        # reaches is linked if a city of the zone has track to a port arrow on the same sea zone (an offshore
        # port, §11.3.6, needs no arrow; the city still needs track).
        def national_linked?(stop, corporation)
          national_track_linked?(stop, corporation) || national_sea_linked?(stop, corporation)
        end

        def national_track_linked?(stop, corporation)
          skip = graph_skip_paths(corporation)
          stop.paths.any? do |start|
            next false if skip&.key?(start)

            catch(:linked) do
              start.walk(skip_paths: skip, converging: false) do |path, _visited, _counter, _converging|
                throw :linked, true if path.nodes.any? { |node| node != stop && node.respond_to?(:route_base_revenue) }
              end
              false
            end
          end
        end

        def national_sea_linked?(stop, corporation)
          return false unless stop.offboard? && national_sea_only?(stop)

          zones = port_accesses(stop).map(&:zone).compact
          national_zone_stops(corporation).any? do |city|
            city.city? && !city.paths.empty? && port_accesses(city).any? do |access|
              zones.include?(access.zone) && (access.exit == :offshore || city.exits.include?(access.exit))
            end
          end
        end

        # ASSUMPTION (workshop #64): a red zone only the sea reaches is one whose every track leads to a port
        # arrow or a ferry end of its hex (PORTS).
        def national_sea_only?(stop)
          ports = self.class::PORTS[stop.hex.id]
          !!ports && !stop.exits.empty? && stop.exits.all? { |exit| ports.key?(exit) }
        end
      end
    end
  end
end
