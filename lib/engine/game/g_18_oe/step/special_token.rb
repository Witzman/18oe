# frozen_string_literal: true

require_relative '../../../step/special_token'

module Engine
  module Game
    module G18OE
      module Step
        class SpecialToken < Engine::Step::SpecialToken
          # §11.6.4 para. 2 (workshop #352): a paid special token obeys the same guard.
          def pay_token_cost(entity, cost, city)
            @game.check_first_round_spend!(entity, cost, what: 'a token')
            super
          end

          def process_place_token(action)
            company = action.entity
            return process_pass_token(action) if @game.pass_token_company?(company)
            return process_free_token(action) if company.id == 'WS'

            wien = ferry_payer(action)
            without_price(action.token, wien) { super(action) }
            @game.remove_wcf_placeholder! if company.id == 'WCF'
            return unless wien

            @log << "#{wien.name} pays for the #{company.name} token"
            close_after_use!(wien)
          end

          # §14.5/§14.6 (#79, #80): the pass-through token of the private goes into an extra position of the city:
          # free, no connection, no token of the RR used, and the Place Token step stays open.
          def available_tokens(entity)
            return super unless @game.pass_token_company?(entity)

            [Engine::Token.new(@game.token_owner(entity), type: :pass)]
          end

          # The hexes with a city the private's token may take (the enumerator, LegalActions#token_targets, then
          # asks #pass_city_ok? for each city of them).
          def available_hex(entity, hex)
            return super unless site_checked?(entity)

            hex.tile.cities.any? { |city| pass_city_ok?(entity, city) }
          end

          def pass_city_ok?(entity, city)
            return true unless site_checked?(entity)

            operator = @game.token_owner(entity)
            return @game.pass_token_site_error(entity, city, operator).nil? if @game.pass_token_company?(entity)

            free_token_error(operator, city).nil?
          end

          # §14.3 (#77): why the Wien Suedbahnhof token may not go on the city (nil if it may): the city is in the track
          # rights zone and reachable as if the token were paid, and the RR can pay the fee for the ferries and sea
          # zones (§11.2.1), which the private does not cover.
          def free_token_error(operator, city)
            hex = city.hex
            return "#{hex.name} is outside #{operator.name}'s track rights zone" unless @game.city_in_track_rights?(operator, hex)
            return nil if @game.loading
            unless @game.token_graph_for_entity(operator).connected_nodes(operator)[city]
              return "Cannot place token on #{hex.name} because it is not connected"
            end

            fee = @game.cross_water_fee_of(@game.cross_water_token_cost(operator, city), :token).to_i
            return nil if fee.zero? || (fee <= operator.cash && @game.first_round_spend_allowed?(operator, fee))

            "#{operator.name} cannot pay #{@game.format_currency(fee)} for the ferries and sea zones to #{hex.name} (§11.2.1)"
          end

          private

          def site_checked?(entity)
            @game.pass_token_company?(entity) || entity.id == 'WS'
          end

          # §14.3: one token of the RR for free, in the RR's Place Token step (which it takes, as a paid token would).
          def process_free_token(action)
            company = action.entity
            operator = @game.token_owner(company)
            token = action.token
            raise GameError, "#{operator.name} has no token to place" if token.nil? || token.used

            error = free_token_error(operator, action.city)
            raise GameError, error if error

            cost = @game.loading ? nil : @game.cross_water_token_cost(operator, action.city)
            fee = @game.cross_water_fee_of(cost, :token).to_i
            without_price(token, company) { place_token(operator, action.city, token, connected: false) }
            if fee.positive?
              operator.spend(fee, @game.bank)
              @game.log_cross_water_fee(operator, cost, :token, 'the token (§11.2.1)')
            end
            close_after_use!(company)
          end

          # §14.3: the Wien Suedbahnhof of the same owner may pay the ferry token; the action says so with cost 0.
          def ferry_payer(action)
            return unless action.entity.id == 'WCF'
            return if action.cost.nil?
            raise GameError, 'A White Cliffs Ferry token costs nothing only when Wien Suedbahnhof pays it' unless action.cost.zero?

            wien = @game.company_by_id('WS')
            return wien if !wien.closed? && wien.owner == action.entity.owner

            raise GameError, "Wien Suedbahnhof of #{action.entity.owner&.name} cannot pay the ferry token"
          end

          # The token is placed without its price when a private pays; the price stays on the token.
          def without_price(token, payer)
            return yield unless payer && token

            price = token.price
            token.price = 0
            yield
          ensure
            token.price = price if payer && token
          end

          def close_after_use!(company)
            ability = ability(company)
            ability&.use!
            return if ability && !(ability.count&.zero? && ability.closed_when_used_up)

            @game.company_closing_after_using_ability(company)
            company.close!
          end

          def process_pass_token(action)
            company = action.entity
            operator = @game.token_owner(company)
            error = @game.pass_token_site_error(company, action.city, operator)
            raise GameError, error if error

            @game.place_pass_token!(company, action.city, operator)
            @log << "#{operator.name} places the #{company.name} token on #{action.city.hex.name}"
            close_after_use!(company)
          end
        end
      end
    end
  end
end
