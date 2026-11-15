# frozen_string_literal: true

# Fixture catalog (#117): bin/fixture-catalog build | verify [name ...] | list | invariants [every]
ENV['ENGINE_LOG_LEVEL'] ||= '3'
require 'oe/fixture_builder'
require 'oe/invariants'

command = ARGV.shift || 'list'
case command
when 'build'
  Oe::FixtureBuilder.build
when 'list'
  Oe::FixtureCatalog.entries.each { |e| puts format('%-28s %-3s %-14s @%-5d %s', e.name, e.slice, e.game, e.position, e.surface) }
when 'verify'
  names = ARGV.empty? ? Oe::FixtureCatalog.entries.map(&:name) : ARGV
  failed = 0
  names.each do |name|
    problems = Oe::FixtureCatalog.problems(Oe::FixtureCatalog.check(name))
    failed += 1 unless problems.empty?
    puts "#{problems.empty? ? 'ok  ' : 'FAIL'} #{name}#{problems.empty? ? '' : "\n     #{problems.join("\n     ")}"}"
  end
  exit(failed.zero? ? 0 : 1)
when 'invariants'
  # #138: every catalog state, then every `every`-th (default 50th) state of each replayed log.
  every = (ARGV.first || 50).to_i
  found = Oe::FixtureCatalog.entries.flat_map do |e|
    Oe::Invariants.run(Oe::FixtureCatalog.game_at(e)).map { |v| [e.name, v] }
  end
  Oe::FixtureCatalog.catalog['games'].each_key do |name|
    found.concat(Oe::Invariants.check_log(Oe::FixtureCatalog.log_file(name), every: every).map { |pos, v| ["#{name}@#{pos}", v] })
  end
  found.each { |where, v| puts "#{where}: #{v}" }
  puts Oe::Invariants.report(found.map(&:last))
  exit(Oe::Invariants.failures(found.map(&:last)).empty? ? 0 : 1)
else
  warn 'usage: bin/fixture-catalog build | verify [name ...] | list | invariants [every]'
  exit 2
end
