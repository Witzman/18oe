# frozen_string_literal: true

# Fixture catalog (#117): bin/fixture-catalog build <game> | diff <game> | verify [name ...] | list | invariants [every]
ENV['ENGINE_LOG_LEVEL'] ||= '3'
require 'fileutils'
require 'oe/fixture_builder'
require 'oe/invariants'

command = ARGV.shift || 'list'
case command
when 'build'
  # build <game> [--to DIR]: one game per call (a game takes minutes); --to writes elsewhere (a check run)
  to = ARGV.index('--to') && ARGV.slice!(ARGV.index('--to'), 2).last
  games = ARGV.dup
  if games.empty?
    warn "usage: bin/fixture-catalog build <game> [--to DIR]   games: #{Oe::FixtureCatalog.catalog['games'].keys.join(', ')}"
    exit 2
  end
  if to
    FileUtils.mkdir_p(to)
    FileUtils.cp(File.join(Oe::FixtureCatalog::DIR, 'catalog.json'), File.join(to, 'catalog.json'))
    Oe::FixtureBuilder.build(to, Oe::FixtureBuilder.definition, only: games)
  else
    Oe::FixtureBuilder.build(only: games)
  end
when 'diff'
  # diff <game>: what a rebuild would change, nothing written (a game takes minutes)
  games = ARGV.empty? ? (warn('usage: bin/fixture-catalog diff <game>'); exit(2)) : ARGV
  games.each { |g| puts Oe::FixtureBuilder.report(Oe::FixtureBuilder.diff(g)) }
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
  warn 'usage: bin/fixture-catalog build <game> [--to DIR] | diff <game> | verify [name ...] | list | invariants [every]'
  exit 2
end
