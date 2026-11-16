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

    def build(dir = FixtureCatalog::DIR, definition = definition(dir), out: $stdout)
      errors = FixtureCatalog.static_errors(definition)
      raise "catalog is not well formed:\n#{errors.join("\n")}" unless errors.empty?

      FileUtils.mkdir_p(dir)
      games = definition['games'].to_h do |name, spec|
        result = Playthrough.run(players: spec['players'], seed: spec['seed'], max_actions: spec['max_actions'],
                                 player: spec['player'].to_sym)
        out.puts "#{name}: #{result.status} after #{result.actions} actions"
        entries = definition['entries'].select { |e| e['game'] == name }
        found = FixtureCatalog.scan(spec, entries, result.log)
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
      out.puts "wrote #{definition['entries'].size} entries, #{games.size} logs to #{dir}"
    end
  end
end
