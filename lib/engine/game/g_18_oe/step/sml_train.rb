# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18OE
      module Step
        # §14.10 Swift Metropolitan Line: from Train Phase 4 the owner designates one RR he controls to receive
        # one unclaimed rusted 2+2. The private acts as its own entity through the upstream `choose` action,
        # the RR is the action's target (the RR operating, before it runs trains).
        class SmlTrain < Engine::Step::Base
          ACTIONS = %w[choose].freeze
          CHOICE = 'sml_train'

          def actions(entity)
            usable?(entity) ? ACTIONS : []
          end

          def blocks?
            false
          end

          def choices
            { CHOICE => 'Take rusted 2+2' }
          end

          def choice_name
            'Swift Metropolitan Line'
          end

          # The RRs the private may give the train to now.
          def corporations(entity)
            operator = @game.current_entity
            usable?(entity) && operator ? [operator] : []
          end

          def process_choose(action)
            raise GameError, "Unknown choice #{action.choice}" unless action.choice == CHOICE

            company = action.entity
            raise GameError, "#{company.name} cannot take a train now" unless usable?(company)
            unless corporations(company).include?(action.target)
              raise GameError, "#{action.target&.name || 'No RR'} cannot receive the train of #{company.name}"
            end

            @game.sml_assign!(company, action.target)
          end

          private

          def usable?(entity)
            return false unless entity.company? && entity == @game.sml_company
            return false if @game.sml_train || entity.closed? || !entity.owner&.player?
            return false unless @game.phase.name.to_i >= 4 && @game.sml_pool.any?

            operator = @game.current_entity
            operator&.corporation? && operator.owner == entity.owner && !@round.active_step.is_a?(Engine::Step::Route)
          end
        end
      end
    end
  end
end
