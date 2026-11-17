# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # Minor L (Krasnaya Strela), rulebook 15.11 (p. 46): the minor's marker, assigned to one train, adds one
      # to that train's city limit and to the number of towns it may count ("+1+1"): a 2+2 runs as a 3+3, an
      # 8+8 as a 9+9, a 4 as a 5+1. On a "D" train the extra city does not double: any one city of the
      # extended route may be chosen not to double (the cheapest is best, so that one is taken). The marker
      # may be reassigned each OR at the beginning of the RR's run trains step. §12.1: it may be used on a
      # train combined for the Orient Express. §15.11 / §11.6.2: it does not raise the train's level for a
      # Pullman (the train's name and level stay as they are).
      #
      # The marker is the upstream `assign` action (as Minor D's token, G18OE::GreenJunction), offered in
      # the run trains step (G18OE::Step::Route) with a train as its target. While assigned, the train's
      # distance rows carry the +1+1 (as a combined train's rows carry the sum, Step::Route#combined_train!),
      # so the distance check, the stop choice, the route search and the view all see the larger train. The
      # rows are given back at the end of the RR's operating turn (upstream after_end_of_operating_turn), so
      # a train sold or rusted later never keeps them. The holder is whoever holds the charter's ability
      # object: it moves to the major on a merge (Game#add_minor_charter!).
      #
      # ASSUMPTIONS (rules silent, marked in workshop #76): the marker is assigned once per operating turn,
      # before the routes are run; on a D train the extra town counts at its single value (§11.3.9: D trains
      # double cities and red zones, towns are not part of a D train's total).
      module KrasnayaStrela
        KRASNAYA_STRELA_ID = 'L'

        attr_reader :krasnaya_train

        def setup_krasnaya_strela!
          @krasnaya_ability = corporation_by_id(KRASNAYA_STRELA_ID)&.abilities&.first
          @krasnaya_train = nil
          @krasnaya_rows = nil
        end

        def krasnaya_holder?(entity)
          !@krasnaya_ability.nil? && entity.respond_to?(:abilities) && entity.abilities.include?(@krasnaya_ability)
        end

        # Trains of the holder that may take the marker now: once per operating turn, trains that have not run.
        def krasnaya_trains(entity)
          return [] if !krasnaya_holder?(entity) || @krasnaya_train

          entity.trains.reject(&:operated)
        end

        def krasnaya_assign!(entity, train)
          raise GameError, "#{entity.name} cannot assign the Krasnaya Strela marker now" unless krasnaya_holder?(entity)
          raise GameError, "#{train&.name} cannot take the Krasnaya Strela marker" unless krasnaya_trains(entity).include?(train)

          @krasnaya_train = train
          @krasnaya_rows = train.distance
          train.distance = krasnaya_rows(train)
          @log << "#{entity.name} assigns the Krasnaya Strela marker (+1+1) to its #{train.name} train"
        end

        # Gives the train its own rows back (end of the holder's operating turn).
        def krasnaya_release!
          return unless @krasnaya_train

          @krasnaya_train.distance = @krasnaya_rows
          @krasnaya_train = nil
          @krasnaya_rows = nil
        end

        def krasnaya_train?(train)
          !@krasnaya_train.nil? && @krasnaya_train == train
        end

        # The rows of a train with the marker: one more city place, one more town counted.
        def krasnaya_rows(train)
          d_train = (train.multiplier || 1) > 1
          train.distance.map do |row|
            row = row.dup
            if row['nodes'] == ['town']
              row['pay'] += 1
              row['multiplier'] = 1 if d_train
            else
              row['pay'] += 1
              row['visit'] += 1 if row['visit']
            end
            row
          end
        end

        # §15.11: on a D train the extra city does not double; the cheapest city of the route stays single.
        def krasnaya_revenue_change(route, stops)
          train = route.train
          return 0 if !krasnaya_train?(train) || (train.multiplier || 1) <= 1

          places = @krasnaya_rows.reject { |row| row['nodes'] == ['town'] }.sum { |row| row['pay'] }
          cities = stops.reject(&:town?)
          return 0 if cities.size <= places

          -cities.map { |stop| stop.route_base_revenue(route.phase, train) }.min
        end

        def after_end_of_operating_turn(operator)
          super
          krasnaya_release!
        end
      end
    end
  end
end
