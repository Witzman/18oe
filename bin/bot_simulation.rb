# frozen_string_literal: true

# Bot-vs-random simulation and key figures (#38).
#   bin/bot-simulation --players 3-7 --seeds 1-8 [--mix mixed|bots] [--opponent random|strategy]
#                      [--jobs 4] [--max-actions N]   (default: 20000 bots-only, 3000 mixed)
# Mixed tables are compared at the action cap: games with random seats do not reach their end.
# Prints one line per game and a summary table; with --json FILE also writes the raw results.

require "optparse"
require "json"
ENV["ENGINE_LOG_LEVEL"] ||= "3"
require "oe/bot_simulation"

opts = { players: [4], seeds: [1], mix: :mixed, opponent: :random, jobs: 1, max_actions: nil, json: nil }
range = lambda do |text|
  first, last = text.split("-", 2).map(&:to_i)
  (first..(last || first)).to_a
end
OptionParser.new do |o|
  o.on("--players N|A-B") { |v| opts[:players] = range.call(v) }
  o.on("--seeds N|A-B") { |v| opts[:seeds] = range.call(v) }
  o.on("--mix mixed|bots") { |v| opts[:mix] = v.to_sym }
  o.on("--opponent random|strategy") { |v| opts[:opponent] = v.to_sym }
  o.on("--jobs N", Integer) { |v| opts[:jobs] = v }
  o.on("--max-actions M", Integer) { |v| opts[:max_actions] = v }
  o.on("--json FILE") { |v| opts[:json] = v }
end.parse!

opts[:max_actions] ||= opts[:mix] == :bots ? 20_000 : 3000
opp = opts[:opponent].to_s
jobs = opts[:players].product(opts[:seeds])

# Run each game in a forked child; results come back over a pipe as JSON.
run_one = lambda do |players, seed|
  reader, writer = IO.pipe
  pid = fork do
    reader.close
    begin
      result = Oe::BotSimulation.run(players: players, seed: seed, mix: opts[:mix], opponent: opts[:opponent], max_actions: opts[:max_actions])
      writer.write(JSON.generate(result.to_h.merge("kinds" => result.kinds.transform_values(&:to_s))))
    rescue StandardError => e
      writer.write(JSON.generate("crash" => "#{e.class}: #{e.message}"[0, 200]))
    end
    writer.close
    exit!(0)
  end
  writer.close
  [pid, reader, players, seed]
end

results = []
queue = jobs.dup
running = []
until queue.empty? && running.empty?
  while running.size < opts[:jobs] && !queue.empty?
    running << run_one.call(*queue.shift)
  end
  pid, reader, players, seed = running.shift
  data = reader.read
  Process.wait(pid)
  # A game that crashes (or a child that dies) becomes one "crash" result; the run goes on.
  r = begin
    parsed = JSON.parse(data)
    parsed.key?("crash") ? nil : parsed
  rescue JSON::ParserError
    nil
  end
  r ||= {
    "players" => players, "seed" => seed, "status" => "crash", "actions" => 0, "turn" => 0, "phase" => "?",
    "kinds" => {}, "values" => {}, "floated" => { "minor" => 0, "regional" => 0, "major" => 0, "national" => 0 },
    "closed" => 0, "passes" => {}, "moves" => {}, "seconds" => 0.0,
    "detail" => (JSON.parse(data)["crash"] rescue "child died without a result"),
  }
  results << r
  w = r["values"].max_by { |_, v| v }
  puts format("%dp seed %-3d %-8s %5d actions turn %-3s phase %-3s winner %s(%s) %5.1fs %s",
              r["players"], r["seed"], r["status"], r["actions"], r["turn"], r["phase"], w&.first,
              r["kinds"][w&.first], r["seconds"], r["detail"])
  if (op = r["operating"]) && !op.empty?
    bm = r["bot_move"] || {}
    puts format("    operating: tiles %d, tokens %d, runs %d, revenue %d, payouts %d; above par %d, below par %d, max price %d; " \
                "bot move s: mean %.3f p99 %.3f max %.3f",
                op["tiles"].to_i, op["tokens"].to_i, op["runs"].to_i, op["revenue"].to_i, op["payouts"].to_i,
                op["above_par"].to_i, op["below_par"].to_i, op["max_price"].to_i, bm["mean"].to_f, bm["p99"].to_f, bm["max"].to_f)
  end
  $stdout.flush
end

File.write(opts[:json], JSON.pretty_generate(results)) if opts[:json]

def median(list)
  s = list.sort
  s.empty? ? nil : s[s.size / 2]
end

puts
finished = results.select { |r| r["status"] == "finished" }
puts "games: #{results.size}, finished: #{finished.size}, stops: #{results.group_by { |r| r['status'] }.map { |s, rs| "#{s}=#{rs.size}" }.join(', ')}"
crashed = results.select { |r| r["status"] == "crash" }
crashed.each { |r| puts "CRASH #{r['players']}p seed #{r['seed']}: #{r['detail']}" }
results = results.reject { |r| r["status"] == "crash" } # the figures below only use games that ran
if results.empty?
  puts "no game ran to a result"
  exit(crashed.empty? ? 0 : 1)
end
puts "actions: median #{median(results.map { |r| r['actions'] })}, turns: median #{median(results.map { |r| r['turn'] })}"
puts "final phase: #{results.group_by { |r| r['phase'] }.sort_by { |k, _| k.to_s }.map { |p, rs| "#{p}=#{rs.size}" }.join(', ')}"
puts "floated per game (mean): #{%w[minor regional major national].map { |t| "#{t}=#{(results.sum { |r| r['floated'][t] }.to_f / results.size).round(1)}" }.join(', ')}; closed (mean): #{(results.sum { |r| r['closed'] }.to_f / results.size).round(1)}"

passes = Hash.new(0)
moves = Hash.new(0)
results.each do |r|
  r["passes"].each { |k, v| passes[k] += v }
  r["moves"].each { |k, v| moves[k] += v }
end
puts "share of passes: #{moves.keys.sort.map { |k| "#{k}=#{(100.0 * passes[k] / moves[k]).round(1)}%" }.join(', ')}"

if opts[:mix] == :mixed
  mixed = results.select { |r| r["kinds"].values.uniq.size == 2 }
  better = 0
  winner_bot = 0
  expected = 0.0
  mixed.each do |r|
    vals = r["values"]
    mean = lambda do |kind|
      v = vals.select { |id, _| r["kinds"][id] == kind }.values
      v.sum.to_f / v.size
    end
    better += 1 if mean.call("bot") > mean.call(opp)
    top = vals.max_by { |_, v| v }.first
    winner_bot += 1 if r["kinds"][top] == "bot"
    expected += r["kinds"].values.count("bot").to_f / r["kinds"].size
  end
  puts format("mixed tables: %d, compared at %d actions. bot mean value beats %s mean value: %d (%.0f%%). winner is a bot: %d (%.0f%%; chance level %.0f%%)",
              mixed.size, opts[:max_actions], opp, better, 100.0 * better / [mixed.size, 1].max, winner_bot, 100.0 * winner_bot / [mixed.size, 1].max,
              100.0 * expected / [mixed.size, 1].max)
  ["bot", opp].each do |kind|
    values = mixed.flat_map { |r| r["values"].select { |id, _| r["kinds"][id] == kind }.values }
    mean = values.sum.to_f / [values.size, 1].max
    sd = Math.sqrt(values.sum { |v| (v - mean)**2 } / [values.size, 1].max)
    puts format("  %-6s seats: %d, mean final value %.0f, sd %.0f", kind, values.size, mean, sd)
  end
else
  values = results.flat_map { |r| r["values"].values }
  mean = values.sum.to_f / [values.size, 1].max
  puts format("bot-only: mean final value %.0f, sd %.0f; winner margin (1st - 2nd) median %s",
              mean, Math.sqrt(values.sum { |v| (v - mean)**2 } / [values.size, 1].max),
              median(results.map { |r| s = r["values"].values.sort.reverse; s[0] - s[1] }))
end
