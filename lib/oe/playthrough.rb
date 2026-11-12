# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'legal_actions'
require_relative 'strategy_player'

module Oe
  # Plays one game with random legal actions (Oe::LegalActions) until it ends
  # or something stops it. Measures whether the rules engine carries a whole
  # game (#31); it is not a bot.
  #
  # Choice: first an action *class* uniformly, then an action of that class
  # uniformly. (A plain uniform pick over all actions is dominated by the huge
  # families, e.g. every price for buying a minor.)
  #
  # Outcomes (`Result#status`):
  #   :finished  game.finished
  #   :crash     an exception that is not a GameError (engine bug)
  #   :rejected  GameError on an action the enumerator produced (enumerator or
  #              engine bug)
  #   :dead_end  step is active and offers action types, but no action exists
  #   :limit     max_actions reached
  class Playthrough
    Result = Struct.new(:players, :seed, :status, :actions, :round, :turn, :detail, :seconds,
                        :enumerate_seconds, :max_enumerate_seconds, :log, keyword_init: true) do
      def to_summary
        to_h.reject { |key, _| key == :log }
      end

      def stop_point
        status == :finished ? nil : "#{round} / #{detail}"
      end
    end

    def self.run(**opts)
      new(**opts).run
    end

    def initialize(players:, seed:, max_actions: 20_000, limit: 12, player: :random)
      @player = player
      @players = players
      @seed = seed
      @max_actions = max_actions
      @limit = limit
    end

    def run
      game = Engine::Game::G18OE::Game.new(("A".."Z").first(@players), id: @seed, seed: @seed)
      rng = Random.new(@seed)
      strategist = StrategyPlayer.new(game, rng: rng) if @player == :strategy
      started = clock
      spent = 0.0
      slowest = 0.0
      count = 0
      status = :limit
      detail = nil

      while count < @max_actions
        if game.finished
          status = :finished
          break
        end

        step = game.round.active_step
        t = clock
        actions = Oe::LegalActions.new(game, limit: @limit, rng: rng).call
        took = clock - t
        spent += took
        slowest = took if took > slowest

        if actions.empty?
          status = :dead_end
          detail = "#{short(step)} #{step&.current_entity&.name}: #{step&.current_actions.inspect}"
          break
        end

        action = strategist ? strategist.choose(actions) : actions.group_by(&:class).values.sample(random: rng).sample(random: rng)
        action ||= actions.sample(random: rng)
        game.process_action(action)
        count += 1
        next unless (error = game.exception)

        status = error.is_a?(Engine::GameError) ? :rejected : :crash
        detail = "#{short(step)} #{action.class.name.split('::').last}: #{error.class}: #{error.message[0, 160]}"
        break
      end
      status = :finished if status == :limit && game.finished

      Result.new(players: @players, seed: @seed, status: status, actions: count,
                 round: game.round.class.name.split('::').last, turn: game.turn, detail: detail,
                 seconds: (clock - started).round(2), enumerate_seconds: spent.round(2),
                 max_enumerate_seconds: slowest.round(3), log: game.raw_actions.map { |h| h.reject { |key, _| key == 'created_at' } })
    end

    # Replayable: same players/seed plus the accepted action log.
    def self.write_log(result, dir)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{result.players}p-#{result.seed}.json")
      File.write(path, JSON.pretty_generate(result.to_summary.merge(actions_log: result.log)))
      path
    end

    private

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def short(step)
      step ? step.class.name.split('::').last : 'no step'
    end
  end
end
