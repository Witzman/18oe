# frozen_string_literal: true

module Oe
  # One live move, processed as 18xx.games processes it (assets/app/view/game/actionable.rb, #604):
  # `add_auto_actions: true`, so the engine runs the auto-passes of steps with nothing to do (#589) and
  # rewrites `raw_actions.last` after the step ran. The stored hash then carries what the step filled in
  # (`extra_cost` of a lay_tile, `auto_actions`), which a replay (`game.loading`) takes from the log instead
  # of computing it. A replay of a stored log uses plain `process_action` (it processes the stored auto_actions).
  module Live
    def self.process(game, action)
      game.process_action(action, add_auto_actions: true)
    end
  end
end
