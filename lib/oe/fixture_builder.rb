# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'fixture_catalog'
require_relative 'playthrough'

module Oe
  # Builds the fixture logs (#117): plays the games named in catalog.json (the one definition, #365)
  # with Oe::Playthrough, checks that every entry's finder matches in the result (see
  # Oe::FixtureCatalog for the finder kinds), keeps each log up to the last position its entries need
  # (one more action for an entry that finds the state `before` an action), and writes the logs and
  # the games' `actions`. Entries, finders and gaps are hand data and are written back unchanged.
  # Deterministic (players, seed, player kind), so a rebuild after an engine change shows exactly
  # which entries moved. Only a catalog refresh runs this, never a feature change.
  module FixtureBuilder
    module_function

    # The catalog as a definition: games (players, seed, player, max_actions, file), entries, gaps.
    def definition(dir = FixtureCatalog::DIR)
      FixtureCatalog.catalog(dir)
    end

    # Plays and writes the logs of the games named in `only` (default: all; one game per call is the
    # way to run it, a game takes minutes). Games not named keep their entry in catalog.json as it is.
    def build(dir = FixtureCatalog::DIR, definition = definition(dir), only: nil, out: $stdout)
      errors = FixtureCatalog.static_errors(definition)
      raise "catalog is not well formed:\n#{errors.join("\n")}" unless errors.empty?

      names = only.nil? || only.empty? ? definition['games'].keys : only
      unknown = names - definition['games'].keys
      raise "unknown game #{unknown.join(', ')} (known: #{definition['games'].keys.join(', ')})" unless unknown.empty?

      FileUtils.mkdir_p(dir)
      games = definition['games'].to_h do |name, spec|
        next [name, spec] unless names.include?(name)

        result = FixtureCatalog.play(spec)
        out.puts "#{name}: #{result.status} after #{result.actions} actions"
        entries = definition['entries'].select { |e| e['game'] == name }
        found = FixtureCatalog.scan(spec, entries, result.log, name: name)
        missing = entries.map { |e| e['name'] } - found.keys
        raise "finder never matched: #{missing.join(', ')} (#{name})" unless missing.empty?

        last = entries.map { |e| found[e['name']][:position] + (e.key?('before') ? 1 : 0) }.max || 0
        body = { 'players' => spec['players'], 'seed' => spec['seed'], 'player' => spec['player'],
                 'actions_log' => result.log.first(last) }
        File.write(File.join(dir, spec['file']), JSON.generate(body))
        [name, spec.merge('actions' => last)]
      end
      File.write(File.join(dir, 'catalog.json'),
                 JSON.pretty_generate('games' => games, 'entries' => definition['entries'], 'gaps' => definition['gaps'] || []))
      out.puts "wrote #{names.join(', ')} to #{dir} (#{definition['entries'].size} entries in the catalog)"
    end

    # What a rebuild of one game would change, without writing anything: size of the stored and the fresh
    # log, the first differing action, and per entry its position in the stored and in the fresh log
    # (nil: the finder matches nothing there; :stale: the stored log no longer replays).
    def diff(name, dir = FixtureCatalog::DIR, definition = definition(dir))
      spec = definition['games'].fetch(name)
      stored = FixtureCatalog.stored_log(name, dir)['actions_log']
      result = FixtureCatalog.play(spec)
      entries = definition['entries'].select { |e| e['game'] == name }
      fresh = FixtureCatalog.scan(spec, entries, result.log, name: name)
      old = begin
        FixtureCatalog.scan(spec, entries, stored, name: name)
      rescue FixtureCatalog::StaleLog => e
        e
      end
      { game: name, status: result.status, stored_actions: stored.size, fresh_actions: result.log.size,
        first_difference: FixtureCatalog.first_difference(stored, result.log),
        stale: old.is_a?(StandardError) ? old.message : nil,
        entries: entries.to_h { |e| [e['name'], [old.is_a?(Hash) ? old[e['name']]&.fetch(:position) : :stale, fresh[e['name']]&.fetch(:position)]] },
        stored: stored, fresh: result.log }
    end

    # Text of a diff, for the terminal and the CI step summary.
    def report(d)
      lines = ["#{d[:game]}: fresh game #{d[:status]} after #{d[:fresh_actions]} actions, stored log #{d[:stored_actions]} actions"]
      k = d[:first_difference]
      lines << if k.nil? then 'logs: identical'
               else "logs: first difference at action #{k + 1} (stored #{d[:stored][k]&.fetch('type', nil) || 'end of log'}, fresh #{d[:fresh][k]&.fetch('type', nil) || 'end of log'}); before that identical"
               end
      lines << "stored log: #{d[:stale]}" if d[:stale]
      moved = d[:entries].reject { |_, (a, b)| a == b }
      lines << "entries: #{d[:entries].size}, moved or unmatched: #{moved.size}"
      moved.each { |n, (a, b)| lines << format('  %-28s stored %-6s fresh %s', n, a.inspect, b.nil? ? 'no match (move to gaps with a reason)' : b) }
      lines.join("\n")
    end
  end
end
