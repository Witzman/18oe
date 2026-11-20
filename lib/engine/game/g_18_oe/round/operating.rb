# frozen_string_literal: true

require_relative '../../../round/operating'

module Engine
  module Round
    module G18OE
      class Operating < Engine::Round::Operating
        def abbreviated?
          @game.abbreviated_or?(@round_num)
        end

        # Minor C's choice (§15.6) holds for one OR: reset it before the order is read.
        def select_entities
          @game.golden_bell_reset!
          super
        end

        # The abbreviated OR (§13) has no Golden Bell step, so it keeps the normal order, and no mail contract
        # (Minor K): it only repeats the previous payout (#508 5c).
        def setup
          @game.golden_bell_ask! unless abbreviated?
          @game.pay_mail_contract! unless abbreviated?
          super
        end

        # Nobody operates until Minor C's president has chosen a position.
        def after_setup
          super unless @game.golden_bell_pending?
        end

        def golden_bell_chosen!
          @entities.replace(@game.operating_order)
          @entity_index = 0
          @golden_bell_started = true
          start_operating
        end

        def after_process(action)
          return @golden_bell_started = false if @golden_bell_started

          super
        end

        # §11.6.5: a minor/regional whose certificate sits in the Open Market does not operate.
        def skip_entity?(entity)
          super || (%i[minor regional].include?(entity.type) && entity.receivership?)
        end
      end
    end
  end
end
