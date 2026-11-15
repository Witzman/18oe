# frozen_string_literal: true

require_relative '../../../step/base'
require_relative '../../../action/choose'

module Engine
  module Game
    module G18OE
      module Step
        # Rulebook 15.6: at the start of each OR the president of Minor C (or of the major that owns
        # it) chooses first, last or normal operating position. Same shape as ConvertToNational: the
        # step waits for a player, the choice is an Engine::Action::Choose by that player (served by
        # Oe::LegalActions#plain_choices through `choices`). The round does not begin operating until
        # the choice is made (Round::G18OE::Operating#golden_bell_chosen!).
        class GoldenBellOrder < Engine::Step::Base
          def actions(entity)
            entity == current_entity ? ['choose'] : []
          end

          def active?
            @game.golden_bell_pending?
          end

          def active_entities
            current_entity ? [current_entity] : []
          end

          def current_entity
            @game.golden_bell_pending? ? @game.golden_bell_chooser : nil
          end

          def description
            'Operating position'
          end

          def choice_name
            "Operating position of #{@game.golden_bell_holder&.name} (Minor C, Golden Bell)"
          end

          def choices
            {
              'normal' => 'Normal position',
              'first' => 'Operate first',
              'last' => 'Operate last',
            }
          end

          def help
            "Golden Bell Marketplace (§15.6): #{current_entity&.name} chooses whether " \
              "#{@game.golden_bell_holder&.name} operates first, last or in its normal position this OR."
          end

          def process_choose(action)
            raise GameError, "#{action.entity.name} does not choose the operating position" unless action.entity == current_entity
            raise GameError, "Unknown operating position #{action.choice}" unless choices.key?(action.choice)

            holder = @game.golden_bell_holder
            @game.golden_bell_choose!(action.choice.to_sym)
            @log << "#{action.entity.name} has #{holder.name} operate #{action.choice == 'normal' ? 'in its normal position' : action.choice} this OR"
            @round.golden_bell_chosen!
          end

          def skip!; end
        end
      end
    end
  end
end
