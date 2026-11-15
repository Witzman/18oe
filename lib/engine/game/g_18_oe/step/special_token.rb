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
            super
            @game.remove_wcf_placeholder! if action.entity.id == 'WCF'
          end
        end
      end
    end
  end
end
