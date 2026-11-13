#!/usr/bin/env ruby
# Balanced rspec sharding by measured run time (#279).
#   shard.rb <shard> <total> <glob-exclude-regex-or-"">   prints the spec files of one shard
#   shard.rb --report <rspec.json>                         prints per-file seconds as GitHub annotations
# Times come from .github/rspec-timings.json ({ "spec/x_spec.rb": seconds }); files without an entry get the
# median. Greedy longest-first assignment to the lightest shard. Every spec file lands in exactly one shard.
require "json"

TIMINGS = File.expand_path("../rspec-timings.json", __dir__)

if ARGV[0] == "--report"
  data = JSON.parse(File.read(ARGV[1]))
  per = Hash.new(0.0)
  data["examples"].each { |e| per[e["file_path"].sub(%r{\A\./}, "")] += e["run_time"].to_f }
  puts "::notice::timing-json #{JSON.generate(per.transform_values { |v| v.round(2) })}" # first: annotations are capped at 10 per step
  exit
end

shard, total = ARGV[0].to_i, ARGV[1].to_i
exclude = ARGV[2].to_s.empty? ? nil : Regexp.new(ARGV[2])
files = Dir["spec/**/*_spec.rb"].sort
files = files.reject { |f| f =~ exclude } if exclude
times = File.exist?(TIMINGS) ? JSON.parse(File.read(TIMINGS)) : {}
known = files.map { |f| times[f] }.compact.sort
median = known.empty? ? 1.0 : known[known.size / 2]
loads = Array.new(total, 0.0)
bins = Array.new(total) { [] }
files.sort_by { |f| [-(times[f] || median), f] }.each do |f|
  i = loads.index(loads.min)
  loads[i] += times[f] || median
  bins[i] << f
end
warn "shard #{shard}/#{total}: #{bins[shard - 1].size} files, est #{loads[shard - 1].round(1)} s (all: #{loads.map { |l| l.round(1) }.join(', ')})"
puts bins[shard - 1].sort
