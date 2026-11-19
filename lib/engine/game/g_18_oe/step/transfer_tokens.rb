# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18OE
      module Step
        # §11.5 Transfer Tokens: after the dividend and before Buy Trains a major may buy placed tokens from
        # other majors of the same player, as many as cash and its own free tokens allow. The step blocks only
        # while there is something to buy; the player buys with `choose` or passes.
        class TransferTokens < Engine::Step::Base
          ACTIONS = %w[choose pass].freeze

          def actions(entity)
            return [] unless entity == current_entity && !choices.empty?

            ACTIONS
          end

          def description
            'Transfer Tokens'
          end

          def pass_description
            'Skip Transfer Tokens'
          end

          def choice_name
            'Buy a token or port authority marker'
          end

          def choices
            @game.token_transfer_choices(current_entity).merge(@game.port_authority_transfer_choices(current_entity))
          end

          def process_choose(action)
            return @game.transfer_port_authority!(action.entity, action.choice) if
              @game.port_authority_transfer_choice?(action.choice)

            @game.transfer_token!(action.entity, action.choice)
          end
        end
      end
    end
  end
end
