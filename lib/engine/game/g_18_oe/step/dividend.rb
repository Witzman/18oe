# frozen_string_literal: true

require_relative '../../../step/dividend'
require_relative '../../../step/half_pay'

module Engine
  module Game
    module G18OE
      module Step
        class Dividend < Engine::Step::Dividend
          include Engine::Step::HalfPay

          def actions(entity)
            return [] if %i[minor national].include?(entity.type) || @game.repeated_payout(entity, @round)

            super
          end

          # The abbreviated OR (§13) has no Track step, but OperatingInfo records the laid hexes.
          def round_state
            super.merge(laid_hexes: [])
          end

          # §13 abbreviated OR: the same revenue, paid out the same way. §11.3.10: a national runs no
          # routes; its revenue is counted over its home track rights zone (G18OE::National).
          def total_revenue
            last = @game.repeated_payout(current_entity, @round)
            return last[:revenue] if last
            return @game.national_revenue(current_entity) if current_entity.type == :national

            super
          end

          def process_dividend(action)
            revenue = total_revenue
            super
            @game.record_payout!(action.entity, revenue, action.kind)
          end

          def skip!
            if (last = @game.repeated_payout(current_entity, @round))
              return process_dividend(Action::Dividend.new(current_entity, kind: last[:kind]))
            end

            case current_entity.type
            when :minor
              kind = total_revenue.zero? ? 'withhold' : 'half'
            when :national
              log_national_run(current_entity)
              kind = total_revenue.zero? ? 'withhold' : 'payout'
            else
              return super
            end
            process_dividend(Action::Dividend.new(current_entity, kind: kind))
          end

          def log_national_run(entity)
            revenue = total_revenue
            return if revenue.zero?

            @log << "#{entity.name} runs its national service for #{@game.format_currency(revenue)} " \
                    "(#{@game.national_run_str(entity)})"
          end

          def half_pay_withhold_amount(_entity, revenue)
            (revenue / 2).floor
          end

          def share_price_change(entity, revenue)
            return {} if %i[minor regional].include?(entity.type)
            return { share_direction: :left, share_times: 1 } if revenue.zero?
            return {} if revenue < entity.share_price.price

            { share_direction: :right, share_times: 1 }
          end

          def dividend_types
            case current_entity.type
            when :minor
              %i[half withhold]
            when :national
              %i[payout withhold]
            else
              %i[withhold half payout]
            end
          end
        end
      end
    end
  end
end
