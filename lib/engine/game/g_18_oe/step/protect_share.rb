# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18OE
      module Step
        # §14.4 (3) (#476): "at the moment another player is selling a share of stock" the owner of Barclay, Bevan,
        # Barclay and Tritton may protect that RR's share value marker from moving DOWN for the rest of the SR.
        # The sale (held by Step::BuySellParShares) waits here, as a purchase waits in Step::ReserveShare:
        # `choose` protects, `pass` lets the marker move.
        class ProtectShare < Engine::Step::Base
          CHOICE = 'protect'

          def round_state
            super.merge(pending_share_sale: nil)
          end

          def active?
            !!@round.pending_share_sale
          end

          def blocks?
            active?
          end

          def active_entities
            active? ? [owner] : []
          end

          def actions(entity)
            active? && entity == owner ? %w[choose pass] : []
          end

          def choice_available?(entity)
            active? && entity == owner
          end

          def choices
            { CHOICE => "Protect #{corporation.name}" }
          end

          def choice_name
            "Protect #{corporation.name} from falling? #{@round.pending_share_sale.entity.name} is selling a share"
          end

          def pass_description
            'Let it fall'
          end

          def description
            'Protect Share Value'
          end

          def hide_corporations?
            true
          end

          def process_choose(action)
            raise GameError, 'Cannot protect' unless action.choice == CHOICE

            @game.bbbt_protect_at_sale!(@game.bbbt_company, corporation)
            complete_sale
          end

          def process_pass(action)
            @log << "#{action.entity.name} lets #{corporation.name}'s share value fall (#{@game.bbbt_company.name})"
            complete_sale
          end

          private

          def complete_sale
            held = @round.pending_share_sale
            sell_step.process_sell_shares(held)
            @round.pending_share_sale = nil
          end

          def corporation
            @round.pending_share_sale.bundle.corporation
          end

          def owner
            @game.bbbt_company.owner
          end

          def sell_step
            @round.steps.find { |step| step.is_a?(G18OE::Step::BuySellParShares) }
          end
        end
      end
    end
  end
end
