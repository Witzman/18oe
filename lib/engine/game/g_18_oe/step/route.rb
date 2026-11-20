# frozen_string_literal: true

require_relative '../../../step/route'

module Engine
  module Game
    module G18OE
      module Step
        class Route < Engine::Step::Route
          def actions(entity)
            # §11.3.10: a national runs no routes; Dividend counts its revenue.
            return [] if (entity.corporation? && entity.type == :national) || @game.repeated_payout(entity, @round)

            actions = super
            return actions if actions.empty?

            # §15.11: Minor L's marker, assigned at the beginning of the run trains step (upstream `assign`)
            actions += %w[assign] unless @game.krasnaya_trains(entity).empty?
            actions += %w[choose] unless choices_for(entity).empty?
            return actions if @game.double_head_candidates(entity).size < 2
            return actions if !@game.loading && !@game.orient_express_reachable?(entity)

            actions + %w[double_head_trains]
          end

          # §11.3.9 (#55): the president says which train carries the Pullman; it adds £10 per level of that
          # train. Offered before the routes are run, one choice per train that does not carry it now.
          def choices
            choices_for(current_entity)
          end

          def choice_name
            'Pullman, port authority'
          end

          # §11.3.5 (#56): the port authority marker may be bought before the Buy Trains step, so here too.
          def choices_for(entity)
            pullman_choices(entity).merge(@game.port_authority_choices(entity))
          end

          def port_authority_choices(entity)
            @game.port_authority_choices(entity)
          end

          def pullman_choices(entity)
            return {} unless entity&.corporation? && entity == current_entity && @game.pullman?(entity)
            return {} if entity.type == :national || @round.routes.any?

            carrying = @game.pullman_train(entity)
            entity.trains.reject { |train| train == carrying }.to_h do |train|
              ["pullman_on:#{train.id}", "Attach Pullman to the #{train.name} train"]
            end
          end

          def process_choose(action)
            entity = action.entity
            choice = action.choice
            return @game.buy_port_authority!(entity, choice) if @game.port_authority_choice?(choice)

            raise GameError, "#{choice} is not a Pullman choice on offer (§11.3.9)" unless pullman_choices(entity).key?(choice)

            train = entity.trains.find { |t| t.id == choice.delete_prefix('pullman_on:') }
            @game.pullman_attach!(entity, train)
          end

          def krasnaya_trains(entity)
            @game.krasnaya_trains(entity)
          end

          def process_assign(action)
            entity = action.entity
            raise GameError, "#{entity.name} cannot assign the Krasnaya Strela marker now" unless entity == current_entity
            raise GameError, 'The Krasnaya Strela marker goes on a train' unless action.target.is_a?(Engine::Train)

            @game.krasnaya_assign!(entity, action.target)
          end

          def help
            base_help = super
            # §12.2 (#512): known only once the routes have been searched for this prompt (no search here)
            if current_entity.type == :major && @game.orient_express_required_known?(current_entity)
              base_help = Array(base_help).reject(&:empty?) + [@game.class::ORIENT_EXPRESS_REQUIRED]
            end
            return base_help if current_entity.type != :major || !@game.non_permanent_trains?

            Array(base_help).reject(&:empty?) + [
              '2+2, 3 and 4 trains may be combined into one train to make an Orient Express run. '\
              'A combined train must run an Orient Express route; use Undo to cancel a combination.',
            ]
          end

          def round_state
            super.merge(combined_trains: {}, orient_express_revenue: nil)
          end

          def setup
            super
            @round.combined_trains = {}
            @round.orient_express_revenue = nil
          end

          def process_run_routes(action)
            check_orient_express_duty!(action)
            super
            @round.orient_express_revenue = @game.orient_express_train_revenue(@round.routes)
            remove_combined_trains!
          end

          def process_double_head_trains(action)
            corporation = action.entity
            trains = action.trains
            candidates = @game.double_head_candidates(corporation)

            raise GameError, 'Cannot combine fewer than 2 trains' if trains.size < 2
            raise GameError, 'Cannot combine the same train twice' if trains.uniq.size != trains.size

            trains.each do |train|
              raise GameError, "Cannot combine train #{train.id}" unless candidates.include?(train)
            end

            trains.each { |train| train.operated = true }

            train = combined_train!(trains)
            train.owner = corporation
            corporation.trains << train
            @round.combined_trains[train] = trains

            @log << "#{corporation.name} combines #{trains.map(&:name).sort.join(', ')} into "\
                    "#{an(train.distance[1]['pay'])} #{train.name} train for the Orient Express"
          end

          def an(number)
            case number
            when 8, 11, 18
              'an'
            else
              'a'
            end
          end

          private

          # §12.2 (#512): routes that leave out an Orient Express run the best routes include are rejected.
          # Not while loading: the action was checked when it was first processed, and a replay would run the
          # route search again for every such run.
          def check_orient_express_duty!(action)
            return if @game.loading
            return unless (required = @game.orient_express_required(action.entity, action.routes))

            what = if required[:combine]
                     "Combining #{required[:combine].map(&:name).sort.join(', ')} (§12.1) and running it earns"
                   else
                     'Routes with it earn'
                   end
            raise GameError, "#{@game.class::ORIENT_EXPRESS_REQUIRED} #{what} "\
                             "#{@game.format_currency(required[:revenue])}."
          end

          def remove_combined_trains!
            @round.combined_trains.each_key do |train|
              @game.remove_train(train)
              train.owner = nil
            end
          end

          def combined_train!(trains)
            sym = trains.map(&:id).sort.join('_')

            # §12.1/§15.11: the rows are the sum of the components' rows as they are now (a component may
            # carry the Krasnaya Strela marker), also for a combination already made in an earlier OR
            cities, towns = trains.map { |component| @game.distance(component) }.transpose.map(&:sum)
            distance = [
              { 'nodes' => ['town'], 'pay' => towns, 'visit' => 99 },
              { 'nodes' => %w[city offboard town], 'pay' => cities, 'visit' => cities },
            ]
            if (train = @game.train_by_id("#{sym}-0"))
              train.operated = false
              train.rusted = false
            else
              train = Engine::Train.new(name: sym, distance: distance, price: 0)

              @game.depot.add_train(train)
              @game.update_trains_cache
              @game.remove_train(train)
            end
            train.distance = distance
            train.name = "#{cities}+#{towns}"

            train.reserved = true
            train
          end
        end
      end
    end
  end
end
