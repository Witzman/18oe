# frozen_string_literal: true

# Plays random games and reports how they end.
#   bin/playthrough --players 3-7 --seeds 1-3 [--max-actions 20000] [--out tmp/playthrough]
# One seed/player count is a plain replayable run; ranges give the summary table.

require 'optparse'
ENV['ENGINE_LOG_LEVEL'] ||= '3'
require 'oe/playthrough'

opts = { players: [4], seeds: [1], max_actions: 20_000, player: :random, out: 'tmp/playthrough' }
parse_range = lambda do |text|
  first, last = text.split('-', 2).map(&:to_i)
  (first..(last || first)).to_a
end
OptionParser.new do |o|
  o.on('--players N|A-B') { |v| opts[:players] = parse_range.call(v) }
  o.on('--seeds N|A-B') { |v| opts[:seeds] = parse_range.call(v) }
  o.on('--max-actions M', Integer) { |v| opts[:max_actions] = v }
  o.on('--player random|strategy') { |v| opts[:player] = v.to_sym }
  o.on('--out DIR') { |v| opts[:out] = v }
end.parse!

results = opts[:players].product(opts[:seeds]).map do |players, seed|
  result = Oe::Playthrough.run(players: players, seed: seed, max_actions: opts[:max_actions], player: opts[:player])
  path = Oe::Playthrough.write_log(result, opts[:out])
  puts format('%dp seed %-3d %-9s %6d actions  %-14s turn %-2s %6.1fs (enumerate %5.1fs, max %.2fs)  %s',
              players, seed, result.status, result.actions, result.round, result.turn, result.seconds,
              result.enumerate_seconds, result.max_enumerate_seconds, result.detail)
  puts "    log: #{path}"
  result
end

if results.size > 1
  finished = results.count { |r| r.status == :finished }
  puts "\nfinished #{finished}/#{results.size}"
  puts 'stops: ' + results.group_by(&:status).map { |s, rs| "#{s}=#{rs.size}" }.join(', ')
  puts 'most common stop point:'
  results.reject { |r| r.status == :finished }.group_by { |r| r.detail.to_s.sub(/\A(\w+) \S+:/, "\\1:")[0, 90] }
         .sort_by { |_, rs| -rs.size }.first(5).each { |d, rs| puts "  #{rs.size}x #{d}" }
  total = results.sum(&:actions)
  puts format('enumeration per action: %.1f ms', results.sum(&:enumerate_seconds) * 1000.0 / [total, 1].max)
end
