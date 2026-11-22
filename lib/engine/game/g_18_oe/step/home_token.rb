# frozen_string_literal: true

require_relative '../../../step/home_token'

module Engine
  module Game
    module G18OE
      module Step
        class HomeToken < Engine::Step::HomeToken
          def process_place_token(action)
            minor = action.entity.type == :minor
            hex = action.city.hex
            if minor
              region = @game.region_for_hex(hex)

              raise GameError, "Region #{region} is not available" unless @game.region_available?(region)

              token.price = @game.home_token_cost(action.entity, region)
              top_up_home_token!(action.entity, token.price)
              @game.claim_region!(action.entity, region)
            end

            super

            return if !minor || !@game.remove_patronage!(hex)

            @game.log << "The #{hex.location_name} patronage tile is removed"
          end

          private

          # RB 9.1 (#369): the owning player pays what the minor's treasury lacks for its home token.
          def top_up_home_token!(minor, price)
            missing = price - minor.cash
            return unless missing.positive?

            owner = minor.owner
            owner.spend(missing, minor)
            @game.log << "#{owner.name} tops up #{@game.format_currency(missing)} for #{minor.name}'s home token"
          end
        end
      end
    end
  end
end
