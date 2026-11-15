# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'fixture_catalog'
require_relative 'playthrough'

module Oe
  # Builds the fixture catalog (#117): plays the games named in DEFINITION with
  # Oe::Playthrough, finds the first state that satisfies each entry's finder, keeps the
  # log up to the last position needed, and writes spec/fixtures/games/. Deterministic
  # (players, seed, player kind), so a rebuild after an engine change shows exactly which
  # entries moved.
  #
  # Finder kinds of an entry:
  #   at:    N                                 a fixed position
  #   first: { round:, step: }                 first state in that round class / active step
  module FixtureBuilder
    # games: name => { players:, seed:, player: :strategy|:random, max_actions: }
    # entries: name, surface (rulebook §), slice, game, finder (at/first), note
    DEFINITION = {
      'games' => {
        'strategy-4p-1' => { 'players' => 4, 'seed' => 1, 'player' => 'strategy', 'max_actions' => 3000 },
      },
      'entries' => [
        { 'name' => 'auction-start', 'surface' => '§6/§7 Auktion (Waterfall), Aufbau §3', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'at' => 0, 'note' => 'Erster Zustand: nichts geboten.' },
        { 'name' => 'auction-running', 'surface' => '§6/§7 Auktion: Gebote liegen', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'at' => 200, 'note' => 'Mitten in der Auktion.' },
        { 'name' => 'concession-first', 'surface' => '§8.1 Concession-Runde', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Concession', 'step' => 'Concession' } },
        { 'name' => 'concession-home-token', 'surface' => '§8.1 Concession-Runde, Heimat-Token', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Concession', 'step' => 'HomeToken' } },
        { 'name' => 'stock-first', 'surface' => '§8.2 erste Aktienrunde (kaufen, parren, floaten)', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Stock', 'step' => 'BuySellParShares' } },
        { 'name' => 'stock-home-token', 'surface' => '§8.2 Aktienrunde, Heimat-Token nach Float', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Stock', 'step' => 'HomeToken' } },
        { 'name' => 'operating-track', 'surface' => '§11.1 erste Betriebsrunde, Gleisbau', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Operating', 'step' => 'Track' } },
        { 'name' => 'operating-buy-train', 'surface' => '§11.6 Zugkauf (Reservierung, Pflicht)', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Operating', 'step' => 'BuyTrain' } },
        { 'name' => 'operating-route', 'surface' => '§11.3 Routen (2+2)', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Operating', 'step' => 'Route' } },
        { 'name' => 'operating-dividend', 'surface' => '§11.4 Dividende', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Operating', 'step' => 'Dividend' } },
        { 'name' => 'operating-home-token', 'surface' => '§11.2 Heimat-Token einer Regional/Minor im Betrieb', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Operating', 'step' => 'HomeToken' } },
        { 'name' => 'operating-token', 'surface' => '§11.2 Token setzen', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Operating', 'step' => 'Token' } },
        { 'name' => 'operating-issue-shares', 'surface' => '§11.7 Issue-Step', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Operating', 'step' => 'IssueShares' } },
      ],
      # Surfaces of the slice that no entry covers yet, with the reason (#117 verification).
      'gaps' => [
        { 'surface' => '§13 Spielende durch gesprengte Bank', 'slice' => 'S1',
          'reason' => 'Ganzpartie (etwa 7 min, Regel 22); folgt als eigener Schnitt des Katalogs.' },
        { 'surface' => '§8.4 Reserved Shares, §10.4 Spielerhandel, geparrtes Regional ohne Käufer', 'slice' => 'S1',
          'reason' => 'In Strategie- und Zufallspartien nicht vorgekommen; von Hand zu spielen, Eingabe offen.' },
      ],
    }.freeze

    module_function

    def build(dir = FixtureCatalog::DIR, definition = DEFINITION, out: $stdout)
      FileUtils.mkdir_p(dir)
      positions = Hash.new { |h, k| h[k] = {} }
      logs = {}
      definition['games'].each do |name, spec|
        result = Playthrough.run(players: spec['players'], seed: spec['seed'], max_actions: spec['max_actions'],
                                 player: spec['player'].to_sym)
        logs[name] = result.log
        out.puts "#{name}: #{result.status} after #{result.actions} actions"
        scan(name, spec, logs[name], definition['entries'].select { |e| e['game'] == name }, positions)
      end

      entries = definition['entries'].map do |e|
        position = positions[e['game']].fetch(e['name']) { raise "#{e['name']}: finder never matched" }
        e.slice('name', 'surface', 'slice', 'game', 'note').merge('position' => position[:position], 'expect' => position[:expect])
      end

      games = definition['games'].to_h do |name, spec|
        last = entries.select { |e| e['game'] == name }.map { |e| e['position'] }.max || 0
        file = "#{name}.json"
        body = { 'players' => spec['players'], 'seed' => spec['seed'], 'player' => spec['player'],
                 'actions_log' => logs[name].first(last) }
        File.write(File.join(dir, file), JSON.generate(body))
        [name, { 'file' => file, 'players' => spec['players'], 'seed' => spec['seed'], 'actions' => last }]
      end
      File.write(File.join(dir, 'catalog.json'),
                 JSON.pretty_generate('games' => games, 'entries' => entries, 'gaps' => definition['gaps'] || []))
      out.puts "wrote #{entries.size} entries, #{games.size} logs to #{dir}"
    end

    def scan(_name, spec, log, entries, positions)
      pending = entries.dup
      game = Engine::Game::G18OE::Game.new(("A".."Z").first(spec['players']), id: spec['seed'], seed: spec['seed'])
      step_state = lambda do |count|
        state = FixtureCatalog.describe(game)
        pending.dup.each do |e|
          hit = e.key?('at') ? e['at'] == count : e['first'].all? { |key, want| state[key] == want }
          next unless hit

          positions[e['game']][e['name']] = { position: count, expect: e['first'] || state.slice('round', 'step') }
          pending.delete(e)
        end
      end
      step_state.call(0)
      log.each_with_index do |action, i|
        game.process_action(action)
        raise "replay failed at #{i + 1}: #{game.exception.message}" if game.exception

        step_state.call(i + 1)
        break if pending.empty?
      end
    end
  end
end
