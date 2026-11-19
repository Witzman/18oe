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
            return process_pass_token(action) if @game.pass_token_company?(action.entity)

            super
            @game.remove_wcf_placeholder! if action.entity.id == 'WCF'
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
            return super unless @game.pass_token_company?(entity)

            hex.tile.cities.any? { |city| pass_city_ok?(entity, city) }
          end

          def pass_city_ok?(entity, city)
            return true unless @game.pass_token_company?(entity)

            @game.pass_token_site_error(entity, city, @game.token_owner(entity)).nil?
          end

          private

          def process_pass_token(action)
            company = action.entity
            operator = @game.token_owner(company)
            error = @game.pass_token_site_error(company, action.city, operator)
            raise GameError, error if error

            @game.place_pass_token!(company, action.city, operator)
            @log << "#{operator.name} places the #{company.name} token on #{action.city.hex.name}"
            ability = ability(company)
            ability.use!
            return unless ability.count&.zero? && ability.closed_when_used_up

            @game.company_closing_after_using_ability(company)
            company.close!
          end
        end
      end
    end
  end
end
