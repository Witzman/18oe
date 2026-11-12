# frozen_string_literal: true

# Measures Oe::LegalActions per step class over whole strategy games (#87).
#   bin/enumeration-timing --players 3-7 --seeds 1-2 [--max-actions 20000]
ENV['ENGINE_LOG_LEVEL'] ||= '3'
require 'optparse'
require 'oe/enumeration_timing'

opts = { players: [3, 5, 7], seeds: [1, 2], max_actions: 20_000 }
range = lambda do |text|
  first, last = text.split('-', 2).map(&:to_i)
  (first..(last || first)).to_a
end
OptionParser.new do |o|
  o.on('--players N|A-B') { |v| opts[:players] = range.call(v) }
  o.on('--seeds N|A-B') { |v| opts[:seeds] = range.call(v) }
  o.on('--max-actions M', Integer) { |v| opts[:max_actions] = v }
end.parse!

samples = []
opts[:players].product(opts[:seeds]).each do |players, seed|
  run = Oe::EnumerationTiming.run(players: players, seed: seed, max_actions: opts[:max_actions])
  warn format('%dp seed %d: %d actions, %s', players, seed, run[:actions], run[:status])
  samples.concat(run[:samples])
end
puts Oe::EnumerationTiming.report(samples)
