# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'fixture_catalog'
require_relative 'playthrough'

module Oe
  # Builds the fixture logs (#117): plays the games named in catalog.json (the one definition, #365)
  # with Oe::Playthrough, checks that every entry's finder matches in the result (see
  # Oe::FixtureCatalog for the finder kinds), keeps each log up to the last position its entries need
  # (one more action for an entry that finds the state `before` an action), and writes the logs
  # (logs/<game>.jsonl) and logs/manifest.json. catalog.json (entries, finders, gaps) is hand data and is
  # never written. Deterministic (players, seed, player kind), so a rebuild after an engine change shows
  # exactly which entries moved. Only a catalog refresh runs this, never a feature change.
  module FixtureBuilder
    module_function

    # The catalog as a definition: games (players, seed, player, max_actions), entries, gaps.
    def definition(dir = FixtureCatalog::DIR)
      FixtureCatalog.catalog(dir)
    end

    # Plays and writes the logs of the games named in `only` (default: all; one game per call is the
    # way to run it, a game takes minutes). Games not named keep their log and manifest entry as they are.
    def build(dir = FixtureCatalog::DIR, definition = definition(dir), only: nil, out: $stdout)
      errors = FixtureCatalog.static_errors(definition)
      raise "catalog is not well formed:\n#{errors.join("\n")}" unless errors.empty?

      names = only.nil? || only.empty? ? definition['games'].keys : only
      unknown = names - definition['games'].keys
      raise "unknown game #{unknown.join(', ')} (known: #{definition['games'].keys.join(', ')})" unless unknown.empty?

      logs = manifest(dir)['logs'] || {}
      names.each do |name|
        spec = definition['games'].fetch(name)
        result = FixtureCatalog.play(spec)
        out.puts "#{name}: #{result.status} after #{result.actions} actions"
        entries = definition['entries'].select { |e| e['game'] == name }
        found = FixtureCatalog.scan(spec, entries, result.log, name: name)
        missing = entries.map { |e| e['name'] } - found.keys
        raise "finder never matched: #{missing.join(', ')} (#{name})" unless missing.empty?

        last = entries.map { |e| found[e['name']][:position] + (e.key?('before') ? 1 : 0) }.max || 0
        FixtureCatalog.write_log(name, result.log.first(last), dir)
        logs[name] = log_entry(name, last, found, dir)
      end
      write_manifest(dir, logs)
      out.puts "wrote #{names.join(', ')} to #{dir}/#{FixtureCatalog::LOGS} (#{definition['entries'].size} entries in the catalog)"
    end

    # What the manifest says about one log: the engine commit it was built with, number of actions, SHA-256 of the file, resolved positions
    # (information for the refresh diff; the loader resolves the finders itself).
    def log_entry(name, actions, found, dir)
      { 'engine_sha' => engine_sha, 'actions' => actions, 'sha256' => Digest::SHA256.file(FixtureCatalog.log_path(name, dir)).hexdigest,
        'positions' => found.transform_values { |f| f[:position] } }
    end

    def manifest(dir = FixtureCatalog::DIR)
      path = File.join(dir, FixtureCatalog::LOGS, 'manifest.json')
      File.exist?(path) ? JSON.parse(File.read(path)) : {}
    end

    def write_manifest(dir, logs)
      File.write(File.join(dir, FixtureCatalog::LOGS, 'manifest.json'),
                 "#{JSON.pretty_generate('logs' => logs.sort.to_h)}\n")
    end

    # Commit of the product the logs were built with (nil outside a git checkout).
    def engine_sha
      sha = IO.popen(%w[git rev-parse HEAD], chdir: File.expand_path('../..', __dir__), err: File::NULL, &:read).to_s.strip
      sha.empty? ? nil : sha
    rescue SystemCallError
      nil
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
