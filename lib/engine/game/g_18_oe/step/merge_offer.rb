# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18OE
      module Step
        # §10.5 (#65, #467): a merger into another player's major needs both owners' agreement and may include
        # personal cash between them (never RR treasury). The rulebook names no direction, so the price is part
        # of the president's offer: choice 'merge_offer' (no cash) or 'merge_offer:<n>', n > 0 the president
        # pays the minor's owner, n < 0 the owner pays the president. The owner must take a single offer
        # (§10.5) unless it demands payment from him: then he may decline it (pass).
        class MergeOffer < Engine::Step::Base
          OFFER = 'merge_offer'
          PRICE = /\A#{OFFER}:(-?\d+)\z/

          def round_state
            super.merge(merge_offer: nil)
          end

          def active?
            !!@round.merge_offer
          end

          def blocks?
            active?
          end

          def active_entities
            return [] unless active?

            [asking? ? asked.owner : minor.owner]
          end

          def context_entities
            [minor]
          end

          def active_context_entity
            minor
          end

          def override_entities
            return [] unless active?

            @round.merge_offer[:presidents]
          end

          def actions(entity)
            return [] unless active?
            return %w[choose pass] if asking? && entity == asked.owner
            return [] unless entity == minor.owner

            declinable? ? %w[choose pass] : ['choose']
          end

          def choice_available?(entity)
            active_entities.include?(entity)
          end

          def choices
            return { OFFER => asked.name } if asking?

            @round.merge_offer[:offers].to_h { |major| [major.id, offer_label(major)] }
          end

          def choice_name
            return "Offer to merge #{minor.name} into" if asking?

            "Merge #{minor.name} into"
          end

          def description
            'Merger Offer'
          end

          def pass_description
            'Decline'
          end

          def hide_corporations?
            true
          end

          def start!(minor, action)
            queue = @game.merge_offer_majors(minor)
            @round.merge_offer = {
              minor: minor,
              action: action,
              queue: queue,
              presidents: queue.map(&:owner).uniq,
              offers: [],
              prices: {},
            }
            advance!
          end

          def process_choose(action)
            if asking?
              price = offered_price(action.choice)
              major = asked
              check_cash!(major, price)
              @round.merge_offer[:queue].shift
              @round.merge_offer[:offers] << major
              @round.merge_offer[:prices][major] = price
              @log << "#{major.name} offers for #{minor.name}#{price_log(major, price)}"
              advance!
            else
              major = @round.merge_offer[:offers].find { |offered| offered.id == action.choice }
              raise GameError, "#{action.choice} has not offered for #{minor.name}" unless major

              resolve!(major)
            end
          end

          def process_pass(action)
            return decline_all!(action) unless asking?

            major = @round.merge_offer[:queue].shift
            @log << "#{action.entity.name} declines to offer #{major.name} for #{minor.name}"
            advance!
          end

          private

          def offered_price(choice)
            return 0 if choice == OFFER

            match = PRICE.match(choice.to_s)
            raise GameError, 'Cannot make that offer' unless match

            match[1].to_i
          end

          # The payer of the settlement must have the personal cash (§10.5: never the RR treasury).
          def check_cash!(major, price)
            payer = price.positive? ? major.owner : minor.owner
            return if price.zero? || payer.cash >= price.abs

            raise GameError, "#{payer.name} does not have #{@game.format_currency(price.abs)} cash for this merger"
          end

          def price_of(major)
            @round.merge_offer[:prices][major] || 0
          end

          def declinable?
            offers = @round.merge_offer[:offers]
            !asking? && offers.any? && offers.all? { |major| price_of(major).negative? }
          end

          def decline_all!(action)
            raise GameError, 'Cannot decline' unless declinable?

            @log << "#{action.entity.name} declines the offers for #{minor.name}"
            @round.merge_offer[:offers].clear
            settle_without_offers!
          end

          def offer_label(major)
            price = price_of(major)
            return major.name if price.zero?

            owner_pays = price.negative?
            "#{major.name} (#{owner_pays ? 'you pay' : 'pays you'} #{@game.format_currency(price.abs)})"
          end

          def price_log(major, price)
            return '' if price.zero?

            " (#{price.positive? ? major.owner.name : minor.owner.name} pays #{@game.format_currency(price.abs)})"
          end

          def settle_cash!(major)
            price = price_of(major)
            return if price.zero?

            check_cash!(major, price)
            payer, payee = price.positive? ? [major.owner, minor.owner] : [minor.owner, major.owner]
            payer.spend(price.abs, payee)
            @log << "#{payer.name} pays #{@game.format_currency(price.abs)} to #{payee.name}"
          end

          def minor
            @round.merge_offer[:minor]
          end

          def asking?
            !@round.merge_offer[:queue].empty?
          end

          def asked
            @round.merge_offer[:queue].first
          end

          def advance!
            return if asking?

            offers = @round.merge_offer[:offers]
            return resolve!(offers.first) if offers.size == 1 && !price_of(offers.first).negative?
            return unless offers.empty?

            settle_without_offers!
          end

          def settle_without_offers!
            offer = @round.merge_offer
            @round.merge_offer = nil
            @log << "No offers for #{offer[:minor].name}"
            # A Stock Round offer (§10.5) has no abandon: without an own major to merge into, the owner's
            # turn goes on as before (the offer used no stock action).
            return if offer[:action].choice == 'offer_or_merge' && @game.merge_targets(offer[:minor].owner, offer[:minor]).empty?

            if offer[:action].choice == 'offer_or_abandon'
              @game.abandon_minor!(offer[:minor])
            else
              @round.merge_minor = offer[:minor]
              buy_step.track_action(offer[:action], offer[:minor])
            end
          end

          def resolve!(major)
            settle_cash!(major)
            offer = @round.merge_offer
            @round.merge_offer = nil
            buy_step.track_action(offer[:action], offer[:minor])
            merge_step.merge!(offer[:minor], major)
          end

          def buy_step
            @round.steps.find { |step| step.is_a?(G18OE::Step::BuySellParShares) }
          end

          def merge_step
            @round.steps.find { |step| step.is_a?(G18OE::Step::MergeMinor) }
          end
        end
      end
    end
  end
end
