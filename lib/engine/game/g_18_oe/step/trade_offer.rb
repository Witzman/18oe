# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18OE
      module Step
        # §10.4 (#202): "A player may purchase minors or face up privates from another player at a mutually
        # agreed upon price." The buyer's buy_company / buy_corporation from another player is an offer
        # (Step::BuySellParShares parks it in @round.trade_offer); this step asks the seller at once:
        # `choose` 'accept_trade' executes the trade as the buyer's stock action, `pass` declines it and the
        # buyer keeps the turn. Pattern of Step::ReserveShare (an interruption of the buyer's turn); the
        # offer/accept/reject flow follows the engine's Rolling Stock ProposeAndPurchase, kept to the actions
        # 18OE already has. An offer never outlives the buyer's turn: it blocks the round until answered.
        class TradeOffer < Engine::Step::Base
          ACCEPT = 'accept_trade'

          def round_state
            super.merge(trade_offer: nil)
          end

          def active?
            !!@round.trade_offer
          end

          def blocks?
            active?
          end

          def active_entities
            active? ? [seller] : []
          end

          def actions(entity)
            active? && entity == seller ? %w[choose pass] : []
          end

          def choice_available?(entity)
            active? && entity == seller
          end

          def choices
            { ACCEPT => 'Accept' }
          end

          def choice_name
            "#{buyer.name} offers #{terms} for #{wanted}"
          end

          def pass_description
            'Decline'
          end

          def description
            'Trade Offer'
          end

          def hide_corporations?
            true
          end

          def pending_offer
            @round.trade_offer
          end

          def process_choose(action)
            raise GameError, 'Cannot choose that' unless action.choice == ACCEPT
            raise GameError, "#{buyer.name} no longer has the cash for this trade" if offer.price > buyer.cash

            held = offer
            @log << "#{seller.name} accepts"
            @round.trade_offer = nil
            buy_step.execute_trade(held)
          end

          def process_pass(_action)
            @log << "#{seller.name} declines the offer for #{target.name}"
            @round.trade_offer = nil
          end

          private

          def offer
            @round.trade_offer
          end

          def terms
            parts = offer.give.map(&:name)
            parts << @game.format_currency(offer.price) if offer.price.positive? || parts.empty?
            parts.join(' and ')
          end

          def wanted
            [target, *offer.also].map(&:name).join(' and ')
          end

          def buyer
            offer.entity
          end

          def target
            offer.is_a?(Engine::Action::BuyCorporation) ? offer.corporation : offer.company
          end

          def seller
            target.owner
          end

          def buy_step
            @round.steps.find { |step| step.is_a?(G18OE::Step::BuySellParShares) }
          end
        end
      end
    end
  end
end
