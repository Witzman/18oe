# frozen_string_literal: true

module Oe
  class ScriptGame
    # The run's list: which round/step/action combinations were executed, which
    # target combinations are missing, retrieval times, size of prompt.actions.
    module Report
      module_function

      def percentile(values, fraction)
        return 0.0 if values.empty?

        sorted = values.sort
        sorted[[(sorted.size * fraction).ceil - 1, 0].max]
      end

      def lines(result)
        ledger = result.ledger
        out = []
        out << "Slice #{result.slice}: game #{result.game_id}, seed #{result.seed}, #{result.actions} actions in #{result.seconds} s, " \
               "#{result.finished ? 'finished' : "NOT finished (#{result.status})"}"
        out << "Standings: #{result.standings.map { |s| "#{s['player']}=#{s['value']}" }.join(' ')}" if result.standings && result.finished
        out << ""
        out << "Executed (#{ledger.executed.size} combinations):"
        ledger.executed.sort.each { |key, n| out << format("  %-58s %5d%s", key, n, result.targets.include?(key) ? "" : "  (extra)") }
        out << ""
        out << "Target combinations missing (#{result.missing.size}):"
        out.concat(result.missing.map { |key| "  #{key}#{ledger.offered.key?(key) ? ' (offered, never taken)' : ' (never offered)'}" })
        out << "  none" if result.missing.empty?
        out << ""
        out << "Offered but never executed:"
        never = ledger.offered.keys - ledger.executed.keys
        out.concat(never.sort.map { |key| "  #{key} (#{ledger.offered[key]}x)" })
        out << "  none" if never.empty?
        out << ""
        gets = ledger.get_seconds
        posts = ledger.post_seconds
        out << format("GET /games/:id  n=%d  mean %.3f s  p95 %.3f s  max %.3f s", gets.size, mean(gets), percentile(gets, 0.95), gets.max.to_f)
        out << format("POST actions    n=%d  mean %.3f s  p95 %.3f s  max %.3f s", posts.size, mean(posts), percentile(posts, 0.95), posts.max.to_f)
        out << format("prompt.actions  max %d entries, p95 %d, max %d bytes (prompt as JSON); prompt.ranges max %d",
                      ledger.action_counts.max.to_i, percentile(ledger.action_counts, 0.95), ledger.bytes.max.to_i,
                      ledger.range_counts.max.to_i)
        out << ""
        out << "Problems (#{ledger.problems.size}):"
        out.concat(ledger.problems.first(20).map { |p| "  #{p.kind}: #{p.detail}" })
        out << "  none" if ledger.problems.empty?
        out
      end

      def mean(values)
        values.empty? ? 0.0 : values.sum / values.size
      end
    end
  end
end
