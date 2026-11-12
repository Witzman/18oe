# frozen_string_literal: true

require "json"
require_relative "bot"

module Oe
  # Bot-vs-random simulation (#38): is the bot (#37) a better opponent than
  # random play, and what do its games look like? Plays one table to its end (or
  # a stop) and returns plain numbers.
  #
  # Seats alternate between :bot and the opponent kind (:random or :strategy; which
  # kind starts depends on the seed parity, so odd tables are not always bot-heavy);
  # `mix: :bots` seats bots only. A random seat picks first an action *class*
  # uniformly, then an action of that class (same choice as Oe::Playthrough); a
  # strategy seat plays Oe::StrategyPlayer, the plain rules of #32 that the bot
  # uses as its fallback — so bot vs strategy shows what the bot's own heuristics add.
  class BotSimulation
    CORPORATION_TYPES = %i[minor regional major national].freeze

    Result = Struct.new(:players, :seed, :mix, :kinds, :status, :actions, :turn, :phase, :values, :floated,
                        :closed, :passes, :moves, :detail, :seconds, keyword_init: true) do
      def to_h
        super.transform_keys(&:to_s)
      end

      def winner_kind
        top = values.max_by { |_, v| v }&.first
        kinds[top]
      end

      def mean_value(kind)
        vals = values.select { |id, _| kinds[id] == kind }.values
        vals.empty? ? nil : vals.sum.to_f / vals.size
      end
    end

    def self.run(**opts)
      new(**opts).run
    end

    def initialize(players:, seed:, mix: :mixed, opponent: :random, max_actions: 20_000, limit: 12)
      @opponent = opponent
      @players = players
      @seed = seed
      @mix = mix
      @max_actions = max_actions
      @limit = limit
    end

    def kinds_for
      ids = (0...@players).map { |i| "p#{i}" }
      ids.each_with_index.to_h do |id, i|
        kind = @mix == :bots || (i + @seed).even? ? :bot : @opponent
        [id, kind]
      end
    end

    def run
      kinds = kinds_for
      game = Engine::Game::G18OE::Game.new(kinds.keys, id: @seed, seed: @seed)
      rng = Random.new(@seed)
      bot = Oe::Bot.new(game, rng: rng, limit: @limit)
      @strategist = Oe::StrategyPlayer.new(game, rng: rng)
      passes = Hash.new(0)
      moves = Hash.new(0)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      count = 0
      status = :limit
      detail = nil

      while count < @max_actions
        (status = :finished; break) if game.finished

        pid = game.active_players.map(&:id).find { |id| !bot.legal_actions(id).empty? }
        unless pid
          status = :dead_end
          detail = "#{game.round.class.name.split('::').last}/#{game.round.active_step&.class&.name&.split('::')&.last}"
          break
        end

        action = case kinds[pid]
                 when :bot then bot.choose(player_id: pid)
                 when :strategy then @strategist.choose(bot.legal_actions(pid))
                 else random_action(bot, pid, rng)
                 end
        game.process_action(action)
        if game.exception
          status = :rejected
          detail = "#{kinds[pid]} #{action.class.name.split('::').last}: #{game.exception.message[0, 120]}"
          break
        end
        moves[kinds[pid]] += 1
        passes[kinds[pid]] += 1 if action.type == "pass"
        count += 1
      end

      Result.new(
        players: @players, seed: @seed, mix: @mix, kinds: kinds, status: status, actions: count, turn: game.turn,
        phase: game.phase.name.to_s, values: game.result,
        floated: CORPORATION_TYPES.to_h { |t| [t.to_s, game.corporations.count { |c| c.type == t && c.floated? }] },
        closed: game.corporations.count(&:closed?), passes: passes, moves: moves, detail: detail,
        seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end

    private

    def random_action(bot, pid, rng)
      actions = bot.legal_actions(pid)
      actions.group_by(&:class).values.sample(random: rng).sample(random: rng)
    end
  end
end
