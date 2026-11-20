# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18OE
      module Step
        # §14.4 (2) (#514): custodianship "may be exercised at any time during a SR, including at the moment another
        # player is purchasing a share of stock in the owning player's RR". The purchase (held by
        # Step::BuySellParShares) waits here, as a sale waits in Step::ProtectShare: `choose` puts the share into
        # custodianship and the purchase does not happen (the buyer keeps the stock action, as at a reservation,
        # §8.4), `pass` completes it.
        class CustodyShare < Engine::Step::Base
          CHOICE = 'custody'

          def round_state
            super.merge(pending_custody_buy: nil)
          end

          def active?
            !!@round.pending_custody_buy
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
            { CHOICE => "Put the share of #{corporation.name} into custodianship" }
          end

          def choice_name
            "Custodianship for #{corporation.name}? #{buyer.name} is purchasing a share"
          end

          def pass_description
            'Let the purchase happen'
          end

          def description
            'Custodianship'
          end

          def hide_corporations?
            true
          end

          def process_choose(action)
            raise GameError, 'Cannot put the share into custodianship' unless action.choice == CHOICE

            held = @round.pending_custody_buy
            @game.bbbt_custody_at_purchase!(@game.bbbt_company, held.bundle)
            @log << "#{buyer.name}'s purchase is cancelled; #{buyer.name} may choose a different action"
            @round.pending_custody_buy = nil
          end

          def process_pass(action)
            held = @round.pending_custody_buy
            @log << "#{action.entity.name} does not put the share of #{corporation.name} into custodianship " \
                    "(#{@game.bbbt_company.name})"
            buy_step.process_buy_shares(held)
            @round.pending_custody_buy = nil
          end

          private

          def corporation
            @round.pending_custody_buy.bundle.corporation
          end

          def buyer
            @round.pending_custody_buy.entity
          end

          def owner
            @game.bbbt_company.owner
          end

          def buy_step
            @round.steps.find { |step| step.is_a?(G18OE::Step::BuySellParShares) }
          end
        end
      end
    end
  end
end
