# frozen_string_literal: true

module Oe
  class Bot
    # Minor D's Green Junction token (§15.4, workshop #71): the bot places it as soon as it may (the
    # bonus only pays while it is on the map), in a city its own network already reaches, the best
    # paying one first; a city it does not reach yet only when it reaches none. Scored on the full
    # list of the step, not the sampled actions; picked by Pick.weighted (seeded, rule 7).
    class GreenJunction
      # Assumption (rule 10, cheap to change): a reached city is worth this much more than an unreached one.
      REACHED = 100

      def initialize(game, rng)
        @game = game
        @rng = rng
      end

      def choose(assigns)
        entity = assigns.first.entity
        step = @game.round.active_step
        hexes = step.respond_to?(:green_junction_hexes) ? step.green_junction_hexes(entity) : assigns.map(&:target)
        return assigns.first if hexes.empty?

        reached = @game.graph_for_entity(entity).connected_nodes(entity).keys.map(&:hex)
        hex = Pick.weighted(hexes.map { |h| [score(h, reached), h] }, @rng)
        Engine::Action::Assign.new(entity, target: hex)
      end

      private

      def score(hex, reached)
        revenue = hex.tile.cities.map(&:max_revenue).max || 0
        revenue + (reached.include?(hex) ? REACHED : 0)
      end
    end
  end
end
