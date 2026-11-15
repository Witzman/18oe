#!/usr/bin/env ruby
# Failed rspec examples from the JSON report as a short list (#365).
#   rspec-failures.rb <rspec.json>
# Prints "file:line  description  first line of the message" to the job log and, if GITHUB_STEP_SUMMARY is
# set, as a markdown table there. Silent (exit 0) when the file is missing or nothing failed.
require "json"

path = ARGV[0]
exit 0 unless path && File.exist?(path)
data = JSON.parse(File.read(path))
failed = data["examples"].select { |e| e["status"] == "failed" }
exit 0 if failed.empty?

rows = failed.map do |e|
  msg = e.dig("exception", "message").to_s.lines.map(&:strip).reject(&:empty?).first.to_s
  ["#{e['file_path'].sub(%r{\A\./}, '')}:#{e['line_number']}", e["full_description"].to_s, msg[0, 300]]
end

puts "#{rows.size} failed example(s):"
rows.each { |loc, desc, msg| puts "  #{loc}  #{desc}\n      #{msg}" }

if (summary = ENV["GITHUB_STEP_SUMMARY"]) && !summary.empty?
  esc = ->(s) { s.gsub("|", "\\|").gsub(/\s+/, " ") }
  File.open(summary, "a") do |f|
    f.puts "### #{rows.size} failed rspec example(s)", "", "| Location | Example | Message |", "|---|---|---|"
    rows.each { |loc, desc, msg| f.puts "| `#{loc}` | #{esc.(desc)} | #{esc.(msg)} |" }
    f.puts
  end
end
