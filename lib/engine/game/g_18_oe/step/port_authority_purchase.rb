# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      module Step
        # §11.3.5 (#56): a major may buy a port authority marker at any time before the Buy Trains step of its
        # OR turn. The Track and Token steps (and the Route step by hand) offer it as a `choose` while they are
        # active anyway; the purchase itself is Game#buy_port_authority!.
        module PortAuthorityPurchase
          def actions(entity)
            actions = super
            return actions unless entity == current_entity && !actions.empty? && !actions.include?('choose')

            port_authority_choices(entity).empty? ? actions : actions + %w[choose]
          end

          def choices
            port_authority_choices(current_entity)
          end

          def choice_name
            'Port authority'
          end

          def port_authority_choices(entity)
            @game.port_authority_choices(entity)
          end

          def process_choose(action)
            @game.buy_port_authority!(action.entity, action.choice)
          end
        end
      end
    end
  end
end
