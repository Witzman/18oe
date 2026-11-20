# frozen_string_literal: true

require_relative '../../../step/home_token'
require_relative 'home_position'

module Engine
  module Game
    module G18OE
      module Step
        class HomeToken < Engine::Step::HomeToken
          include HomePosition

          def process_place_token(action)
            check_home_position!(action)
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

            @game.fulfill_patronage!(action.entity, hex, lowest: true) if minor
          end

          private

          # #369: the owning player pays what the minor's treasury lacks for its home token.
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
