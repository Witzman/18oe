# frozen_string_literal: true

require_relative '../../../step/home_token'

module Engine
  module Game
    module G18OE
      module Step
        # RB 11.1.9, last paragraph: a metropolis home position that triggers the Right-of-Way green tile is not chosen
        # while another position does not (Game#home_position_cities). Oe::LegalActions asks #pass_city_ok? for the same
        # positions.
        module HomePosition
          def pass_city_ok?(_entity, city)
            corporation = token.corporation
            return true unless @game.metropolis_hex?(city.hex) && corporation.corporation?

            @game.home_position_cities(corporation, city.hex).include?(city)
          end

          def check_home_position!(action)
            return if pass_city_ok?(action.entity, action.city)

            raise GameError, "#{token.corporation.name} must choose a home token position that does not need the " \
                             'Right-of-Way green tile (RB 11.1.9)'
          end
        end

        # The operating round's home token step (a tile laid on a metropolis makes SB or MSP choose its position there):
        # the engine's own step plus the position rule. G18OE::Step::HomeToken, which also claims a minor's track rights
        # region, is for the stock and the concession round.
        module Operating
          class HomeToken < Engine::Step::HomeToken
            include HomePosition

            def process_place_token(action)
              check_home_position!(action)
              super
            end
          end
        end
      end
    end
  end
end
