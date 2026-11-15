# frozen_string_literal: true

require_relative '../../../step/token'

module Engine
  module Game
    module G18OE
      module Step
        class Token < Engine::Step::Token
          def actions(entity)
            return ACTIONS if entity == current_entity && !@round.tokened && @game.abilities(entity, :token)

            super
          end

          # §11.6.4 para. 2 (workshop #352): no token while its price would leave the
          # reserved 2+2 unpayable; the step then has nothing to offer.
          def can_place_token?(entity)
            super && @game.first_round_spend_allowed?(entity, min_token_price(available_tokens(entity)))
          end

          def pay_token_cost(entity, cost, city)
            @game.check_first_round_spend!(entity, cost, what: 'a token')
            super
          end

          def available_hex(entity, hex)
            return nil unless @game.city_in_track_rights?(entity, hex)

            super
          end

          def check_connected(entity, city, hex)
            city_string = hex.tile.cities.size > 1 ? " city #{city.index}" : ''
            unless @game.city_in_track_rights?(entity, hex)
              raise GameError, "Cannot place token on #{hex.name} because it is outside #{entity.name}'s track rights zone"
            end

            return if @game.loading || @game.token_graph_for_entity(entity).connected_nodes(entity)[city]

            raise GameError, "Cannot place token on #{hex.name}#{city_string} because it is not connected"
          end
        end
      end
    end
  end
end
