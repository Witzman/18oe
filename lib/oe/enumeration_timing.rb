# frozen_string_literal: true

require_relative 'legal_actions'
require_relative 'strategy_player'

module Oe
  # Times Oe::LegalActions on every turn of a strategy game (#87): the full
  # enumeration (limit: nil, as the view does) and the bot enumeration
  # (limit: 12), grouped by the active step class. Measures only.
  module EnumerationTiming
    Sample = Struct.new(:step, :full, :bot, :full_count, :bot_count, keyword_init: true)
    MODES = { full: 'full (limit nil)', bot: 'bot (limit 12)' }.freeze

    module_function

    def run(players:, seed:, max_actions: 20_000, bot_limit: 12)
      game = Engine::Game::G18OE::Game.new(('A'..'Z').first(players), id: seed, seed: seed)
      rng = Random.new(seed)
      strategist = StrategyPlayer.new(game, rng: rng)
      samples = []
      count = 0
      status = :limit
      while count < max_actions
        (status = :finished) && break if game.finished

        step = game.round.active_step
        name = step ? step.class.name.split('::').last : 'none'
        full, full_time = timed { LegalActions.new(game, limit: nil).call }
        bot, bot_time = timed { LegalActions.new(game, limit: bot_limit, rng: rng).call }
        samples << Sample.new(step: name, full: full_time, bot: bot_time, full_count: full.size, bot_count: bot.size)
        (status = :dead_end) && break if bot.empty?

        game.process_action(strategist.choose(bot) || bot.sample(random: rng))
        count += 1
        (status = :error) && break if game.exception
      end
      { players: players, seed: seed, actions: count, status: status, samples: samples }
    end

    def timed
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t]
    end

    def percentile(sorted, fraction)
      sorted[[(sorted.size * fraction).ceil - 1, 0].max]
    end

    # Rows: [step, mode, n, median_ms, p95_ms, max_ms, max_actions_enumerated]
    def rows(samples)
      samples.group_by(&:step).flat_map do |step, group|
        MODES.keys.map do |mode|
          times = group.map(&mode).sort
          sizes = group.map { |s| s.public_send(:"#{mode}_count") }
          [step, mode, times.size, percentile(times, 0.5) * 1000, percentile(times, 0.95) * 1000, times.last * 1000, sizes.max]
        end
      end.sort_by { |r| [r[1].to_s, -r[4]] }
    end

    def report(samples)
      lines = []
      MODES.each do |mode, label|
        lines << "== #{label} =="
        lines << format('%-28s %7s %10s %10s %10s %8s', 'step', 'n', 'median ms', 'p95 ms', 'max ms', 'max acts')
        selected = rows(samples).select { |r| r[1] == mode }
        selected.each do |step, _, n, med, p95, max, size|
          lines << format('%-28s %7d %10.2f %10.2f %10.2f %8d', step, n, med, p95, max, size)
        end
        all = samples.map(&mode).sort
        lines << format('%-28s %7d %10.2f %10.2f %10.2f', 'ALL', all.size, percentile(all, 0.5) * 1000,
                        percentile(all, 0.95) * 1000, all.last * 1000)
        lines << ''
      end
      lines.join("\n")
    end
  end
end
