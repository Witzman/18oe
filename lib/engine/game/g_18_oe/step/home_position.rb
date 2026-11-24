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

          # The home token of a regional or major was paid at the float (RB 3.2 step 4; a major's is free), so a placement
          # deferred to a later round costs nothing; the engine's Tokener would charge token.price again. A minor's is
          # priced by G18OE::Step::HomeToken (RB 9.1).
          def process_place_token(action)
            home = token
            price = home.price
            home.price = 0 unless home.corporation.type == :minor
            super
          ensure
            home.price = price if home
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
