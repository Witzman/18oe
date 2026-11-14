# frozen_string_literal: true

# Bot game audit (#306): bin/bot-audit --players 3 --seeds 1-3 [--max-actions N] [--json FILE] [--log FILE]
# Plays bots-only tables, checks invariants after every action, reports progress,
# per-step legal/chosen actions and stalls. One game per seed, run sequentially.

require "optparse"
require "json"
ENV["ENGINE_LOG_LEVEL"] ||= "3"
require "oe/bot_audit"

opts = { players: 3, seeds: [1], max_actions: 20_000, json: nil, log: nil }
OptionParser.new do |o|
  o.on("--players N", Integer) { |v| opts[:players] = v }
  o.on("--seeds N|A-B") { |v| a, b = v.split("-", 2).map(&:to_i); opts[:seeds] = (a..(b || a)).to_a }
  o.on("--max-actions M", Integer) { |v| opts[:max_actions] = v }
  o.on("--json FILE") { |v| opts[:json] = v }
  o.on("--log FILE", "one JSON line per action (legal set + chosen); seed is appended to the name") { |v| opts[:log] = v }
end.parse!

results = opts[:seeds].map do |seed|
  io = opts[:log] && File.open("#{opts[:log]}.seed#{seed}.jsonl", "w")
  r = Oe::BotAudit.run(players: opts[:players], seed: seed, max_actions: opts[:max_actions], log: io)
  io&.close
  apm = r.seconds.positive? ? (r.actions / (r.seconds / 60.0)).round : 0
  puts "seed #{seed}: #{r.status} #{r.actions} actions, turn #{r.turn}, #{r.seconds.round(1)}s (#{apm}/min), " \
       "#{r.findings.size} findings, #{r.stalls} stalls"
  r.findings.first(10).each { |f| puts "  [#{f['kind']}] t#{f['turn']} #{f['step']} #{f['message']}" }
  r
end

puts "\nstep                                   offered only-pass visits w/choice skipped  sec(total/max)  chosen"
merged = Hash.new { |h, k| h[k] = { offered: 0, only_pass: 0, visits: 0, visits_with_choice: 0, visits_skipped: 0, seconds: 0.0, max: 0.0, chosen: Hash.new(0) } }
results.each do |r|
  r.steps.each do |k, v|
    m = merged[k]
    [:visits, :visits_with_choice, :visits_skipped].each { |f| m[f] += v[f] }; m[:offered] += v[:offered]; m[:only_pass] += v[:only_pass]; m[:seconds] += v[:seconds]
    m[:max] = [m[:max], v[:max]].max
    v[:chosen].each { |c, n| m[:chosen][c] += n }
  end
end
merged.sort_by { |_, v| -v[:offered] }.each do |k, v|
  puts format("%-38s %7d %9d %6d %8d %7d  %6.1f/%5.2f  %s", k, v[:offered], v[:only_pass], v[:visits], v[:visits_with_choice], v[:visits_skipped], v[:seconds], v[:max], v[:chosen].sort_by { |_, n| -n }.map { |c, n| "#{c}:#{n}" }.join(" "))
end
File.write(opts[:json], JSON.pretty_generate(results.map(&:to_h))) if opts[:json]
exit(results.any? { |r| r.findings.any? } ? 1 : 0)
