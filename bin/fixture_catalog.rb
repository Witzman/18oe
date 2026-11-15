# frozen_string_literal: true

# Fixture catalog (#117): bin/fixture-catalog build | verify [name ...] | list
ENV['ENGINE_LOG_LEVEL'] ||= '3'
require 'oe/fixture_builder'

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
else
  warn 'usage: bin/fixture-catalog build | verify [name ...] | list'
  exit 2
end
