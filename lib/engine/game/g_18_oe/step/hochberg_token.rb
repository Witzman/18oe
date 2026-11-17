# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18OE
      module Step
        # §14.8 Hochberg Mining & Lumber Co.: during the Lay Track step of an RR the owner controls, the
        # private places its token on a rough hex (construction cost of at least 45). The private acts
        # as its own entity through the upstream `choose` action, the hex is the action's target.
        class HochbergToken < Engine::Step::Base
          ACTIONS = %w[choose].freeze
          CHOICE = 'hochberg_token'

          def actions(entity)
            usable?(entity) ? ACTIONS : []
          end

          def blocks?
            false
          end

          def choices
            { CHOICE => 'Place token' }
          end

          def choice_name
            'Hochberg Mining and Lumber'
          end

          def hexes
            @game.hochberg_hexes
          end

          def process_choose(action)
            raise GameError, "Unknown choice #{action.choice}" unless action.choice == CHOICE
            raise GameError, "#{action.entity.name} cannot place its token now" unless usable?(action.entity)
            raise GameError, "#{action.target&.id} cannot take the token" unless hexes.include?(action.target)

            @game.hochberg_place_token!(action.target)
          end

          private

          def usable?(entity)
            return false unless entity.company? && entity == @game.hochberg_company
            return false if @game.hochberg_hex || entity.closed? || !entity.owner&.player?

            operator = @game.current_entity
            operator&.corporation? && operator.owner == entity.owner && @round.active_step.is_a?(Engine::Step::Track)
          end
        end
      end
    end
  end
end
