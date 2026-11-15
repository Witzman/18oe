# frozen_string_literal: true

module Oe
  class Bot
    # Dividends (#327, rule 3 of #140 via #311): pay, half or withhold so the
    # company collects its own cash for the next train, while keeping the share
    # value moving where it can.
    #
    # The share price consequence of each choice is the engine's own
    # (`Dividend#dividend_options`, which passes the amount actually paid out to
    # `share_price_change`; for 'half' that is revenue minus the withheld half,
    # RB 4.4). No parallel market logic here.
    #
    # Major:
    #   - no train of the level on sale (or no train at all) and too little cash
    #     for it -> 'half' when the share value still moves RIGHT (RB 4.4), else
    #     'half' when the retained half covers the train, else 'withhold'
    #   - otherwise 'payout'
    # Regional (no share value movement, PB 588-592):
    #   - 'withhold' while it has no level-3 train and its cash is below that
    #     train's price; otherwise 'payout'
    #
    # Seeded: the ranked first choice most of the time, the second now and then
    # (WEIGHTS). Thresholds and weights are assumptions (rule 10, A5 of
    # notes/reference/bot-input-318.md), tuned after playtests.
    class Dividend
      WEIGHTS = [19, 1].freeze # second choice in 1 of 20 (cf. skip_chance 'standard')
      REGIONAL_TARGET_LEVEL = 3 # A5: regionals keep until they own a level-3 train

      def initialize(game, rng)
        @game = game
        @rng = rng
      end

      def choose(by_class)
        dividends = by_class["Dividend"]
        entity = dividends.first.entity
        by_kind = dividends.to_h { |a| [a.kind, a] }
        ranked = ranking(entity).select { |kind| by_kind[kind] }
        return dividends.first if ranked.empty?

        Pick.weighted(ranked.each_with_index.map { |kind, i| [-i, by_kind[kind]] }, @rng, weights: WEIGHTS)
      end

      # Kinds in order of preference.
      def ranking(entity)
        case entity.type
        when :major then major_ranking(entity)
        when :regional then needs_cash?(entity, regional_target(entity)) ? %w[withhold half] : %w[payout half]
        else %w[payout half withhold]
        end
      end

      private

      def major_ranking(entity)
        target = major_target(entity)
        return %w[payout half] unless needs_cash?(entity, target)

        options = engine_step.dividend_options(entity)
        half = options[:half]
        return %w[half withhold] if half && half[:share_direction] == :right
        return %w[half withhold] if half && entity.cash + retained(half) >= price(target)

        %w[withhold half]
      end

      # The train on sale now, if the major owns nothing of its level.
      def major_target(entity)
        train = @game.depot.upcoming.first
        return unless train
        return if level(train) <= best_level(entity)
        return if entity.trains.size >= @game.train_limit(entity)

        train
      end

      # The first level-3 (or higher) train still to come, while the regional owns none.
      def regional_target(entity)
        return if best_level(entity) >= REGIONAL_TARGET_LEVEL

        @game.depot.upcoming.find { |train| level(train) >= REGIONAL_TARGET_LEVEL }
      end

      def needs_cash?(entity, target)
        target && entity.cash < price(target)
      end

      def retained(option)
        option[:corporation] + option[:divs_to_corporation].to_i
      end

      def best_level(entity)
        entity.trains.map { |train| level(train) }.max || 0
      end

      # '2+2' -> 2, '3' -> 3, '4D' -> 4, '7+7' -> 7
      def level(train)
        train.name.to_i
      end

      # Cheapest variant ('3' at 200 rather than '3+3' at 225).
      def price(train)
        train.variants.values.map { |v| v[:price] }.min || train.price
      end

      def engine_step
        @game.round.active_step
      end
    end
  end
end
