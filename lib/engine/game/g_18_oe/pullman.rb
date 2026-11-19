# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # Pullman cars (§11.6.2, §11.3.9, §15.12 Minor M), workshop #55, part 1: ownership and revenue.
      # A RR owns at most one Pullman; it does not count against the train limit. It adds £10 per level
      # of the train it is attached to; the attachment is automatic, to the RR's highest level train
      # (ASSUMPTION #55: always the most revenue; "the president may specify the train", §11.3.9, comes
      # later). On a combined Orient Express train only the level of one sub-train counts (§12.1).
      #
      # Minor M's ten cars: one is free for M (or the major it merged into) when Train Phase 4 begins
      # (event `pullmans_available`, on the first 4 train); the other nine are bought (part 2). A Pullman
      # that is discarded or a national's goes to the Open Market (a count, not a card).
      #
      # A national's inherent Pullman is counted by National (#64); it never appears in @pullman_owners.
      module Pullman
        PULLMAN_ID = 'M'
        PULLMAN_TOTAL = 10
        PULLMAN_PRICE = 150
        PULLMAN_ROYALTY = 15
        PULLMAN_RR_PRICE = 75

        attr_reader :pullman_supply, :pullman_market, :pullman_owners

        def setup_pullmans!
          @pullman_owners = Set.new
          @pullman_attached = {}
          @pullman_supply = PULLMAN_TOTAL
          @pullman_market = 0
          @pullmans_available = false
        end

        def pullmans_available?
          @pullmans_available
        end

        def pullman?(corporation)
          @pullman_owners.include?(corporation)
        end

        def event_pullmans_available!
          return if @pullmans_available

          @pullmans_available = true
          @log << '-- Event: Pullman cars are now available --'
          @pullman_supply -= 1
          receive_pullman!(pullman_m_holder)
        end

        # Minor M, or the major it merged into (§11.6.2).
        def pullman_m_holder
          m = corporation_by_id(PULLMAN_ID)
          @merged_minors.find { |_major, minors| minors.include?(m) }&.first || m
        end

        # The Pullman of `corporation` comes from Minor M's free car or a purchase; a second one, or one for
        # a national (it has its own), goes to the Open Market at once (§11.6.2, §11.6.2 merge rule).
        def receive_pullman!(corporation)
          if corporation.type == :national || pullman?(corporation)
            @pullman_market += 1
            @log << "#{corporation.name} cannot hold another Pullman; it goes to the Open Market"
          else
            @pullman_owners << corporation
            @log << "#{corporation.name} receives a Pullman"
          end
        end

        # §11.6.2: a discarded Pullman goes to the Open Market, not back to Minor M, with no refund.
        def pullman_to_market!(corporation)
          return unless @pullman_owners.delete?(corporation)

          @pullman_attached.delete(corporation)
          @pullman_market += 1
          @log << "#{corporation.name}'s Pullman goes to the Open Market"
        end

        # §11.6.2: Minor M merged into a major: the major receives the Pullman M owns; if it has one,
        # one of them is discarded to the Open Market (here: M's).
        def pullman_on_merge!(minor, major)
          return unless minor.id == PULLMAN_ID && @pullman_owners.delete?(minor)

          receive_pullman!(major)
        end

        # The RR's train that carries the Pullman: its highest level (a combined train counts the level of
        # its highest sub-train, §12.1).
        def pullman_train(corporation)
          return nil unless pullman?(corporation)

          # §12.1: while a combination exists it is the only train that runs, so the car sits on it
          combined = corporation.trains.find { |train| combined_train?(train) }
          return combined if combined

          chosen = @pullman_attached[corporation]
          return chosen if chosen && corporation.trains.include?(chosen) && !chosen.rusted

          corporation.trains.max_by { |train| pullman_train_level(train) }
        end

        # §11.3.9: "the president may specify the train to which the Pullman is attached".
        def pullman_attach!(corporation, train)
          unless pullman?(corporation) && corporation.trains.include?(train)
            raise GameError, "#{corporation.name} cannot attach a Pullman to that train"
          end

          @pullman_attached[corporation] = train
          @log << "#{corporation.name} attaches its Pullman to its #{train.name} train"
        end

        def pullman_train_level(train)
          parts = @round.respond_to?(:combined_trains) ? @round.combined_trains[train] : nil
          parts ? parts.map { |part| part.sym.to_i }.max : train.sym.to_i
        end

        def pullman_revenue(route)
          corporation = route.corporation
          return 0 unless corporation.respond_to?(:type) && route.train == pullman_train(corporation)

          pullman_train_level(route.train) * National::PULLMAN_PER_LEVEL
        end

        # §11.6.2: who gets the £15 royalty for a car bought from Minor M: the major M merged into, else M
        # itself while it is a floated minor (nobody else is paid).
        def pullman_royalty_receiver
          holder = pullman_m_holder
          holder.type == :minor && !holder.floated? ? nil : holder
        end

        def pullman_from_m_available?
          @pullmans_available && @pullman_supply.positive?
        end

        # Buying takes the car from its source (§11.6.2); the caller pays.
        def pullman_bought_from_m!
          @pullman_supply -= 1
        end

        def pullman_bought_from_market!
          @pullman_market -= 1
        end
      end
    end
  end
end
