# frozen_string_literal: true

module Oe
  class Bot
    # Seeded weighted choice among the best candidates: the top-scored one is
    # the most likely, the next ones still get a chance, so two bots (or two
    # games) do not play identically, while the whole game stays reproducible
    # for a given seed.
    module Pick
      WEIGHTS = [6, 3, 1].freeze

      module_function

      # scored: [[score, item], ...]
      def weighted(scored, rng, weights: WEIGHTS)
        return if scored.empty?

        # Stable order for equal scores (so the seed alone decides, not Ruby's sort).
        top = scored.each_with_index.sort_by { |(score, _), i| [-score, i] }.first(weights.size).map(&:first)
        total = weights.first(top.size).sum
        roll = rng.rand(total)
        top.zip(weights).each do |(_, item), weight|
          return item if roll < weight

          roll -= weight
        end
        top.first.last
      end
    end
  end
end
