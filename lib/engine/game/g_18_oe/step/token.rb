# frozen_string_literal: true

require_relative '../../../step/token'
require_relative 'port_authority_purchase'

module Engine
  module Game
    module G18OE
      module Step
        class Token < Engine::Step::Token
          include PortAuthorityPurchase

          def actions(entity)
            return ACTIONS if entity == current_entity && !@round.tokened && @game.abilities(entity, :token)

            super
          end

          # §11.6.4 para. 2 (workshop #352): no token while its price would leave the
          # reserved 2+2 unpayable; the step then has nothing to offer.
          def can_place_token?(entity)
            super && @game.first_round_spend_allowed?(entity, min_token_price(available_tokens(entity)))
          end

          # §11.2.1 (#360, #61): the fee for the ferries and sea zones to the city is taken before the token stands (it
          # would make the city a station of the RR) and paid with the token's price.
          def place_token(entity, city, token, connected: true, **opts)
            @water_cost = connected ? @game.cross_water_token_cost(entity, city) : nil
            @water_fee = @game.cross_water_fee_of(@water_cost, :token).to_i
            super
          ensure
            @water_cost = @water_fee = nil
          end

          def pay_token_cost(entity, cost, city)
            fee = @water_fee.to_i
            @game.check_first_round_spend!(entity, cost + fee, what: 'a token')
            super(entity, cost + fee, city)
            @game.log_cross_water_fee(entity, @water_cost, :token, 'the token (§11.2.1)') if fee.positive?
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

            return if @game.loading

            unless @game.token_graph_for_entity(entity).connected_nodes(entity)[city]
              raise GameError, "Cannot place token on #{hex.name}#{city_string} because it is not connected"
            end

            # §11.2: "If the RR's treasury has insufficient cash to pay the fees, the token may not be placed."
            fee = @game.cross_water_token_fee(entity, city).to_i
            tokens = available_tokens(entity)
            return if fee.zero? || tokens.empty? || min_token_price(tokens) + fee <= entity.cash

            raise GameError, "#{entity.name} cannot pay the token and #{@game.format_currency(fee)} for the ferries and sea zones " \
                             "to #{hex.name}#{city_string} (§11.2.1)"
          end
        end
      end
    end
  end
end
