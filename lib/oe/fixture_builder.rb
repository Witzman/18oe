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
  #   first: { round:, step:, phase:, finished: }  first state matching all given keys (round class,
  #                                            active step, phase name, finished)
  #   before: { type: }                        the state just before the first logged action of that
  #                                            type (that action is then among the legal ones)
  module FixtureBuilder
    # games: name => { players:, seed:, player: :strategy|:random, max_actions: }
    # entries: name, surface (rulebook §), slice, game, finder (at/first), note
    DEFINITION = {
      'games' => {
        'strategy-4p-1' => { 'players' => 4, 'seed' => 1, 'player' => 'strategy', 'max_actions' => 5100 },
        'strategy-3p-1' => { 'players' => 3, 'seed' => 1, 'player' => 'strategy', 'max_actions' => 3700 },
        'random-4p-1' => { 'players' => 4, 'seed' => 1, 'player' => 'random', 'max_actions' => 2000 },
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
        { 'name' => 'stock-par', 'surface' => '§8.1 Regional parren (Kursstufe waehlen)', 'slice' => 'S1',
          'game' => 'random-4p-1', 'before' => { 'type' => 'par' } },
        { 'name' => 'stock-sell', 'surface' => '§10.1 Anteile verkaufen', 'slice' => 'S2',
          'game' => 'random-4p-1', 'before' => { 'type' => 'sell_shares' } },
        { 'name' => 'stock-convert', 'surface' => '§9.3 Regional zum Major konvertieren', 'slice' => 'S2',
          'game' => 'random-4p-1', 'before' => { 'type' => 'convert' } },
        { 'name' => 'merge-minor', 'surface' => '§10.5 Minor-Merge in den eigenen Major (Angebot)', 'slice' => 'S2',
          'game' => 'random-4p-1', 'first' => { 'round' => 'Stock', 'step' => 'MergeMinor' } },
        { 'name' => 'merge-token', 'surface' => '§10.5 Minor-Merge, Token-Wahl', 'slice' => 'S2',
          'game' => 'random-4p-1', 'first' => { 'round' => 'Stock', 'step' => 'MergeToken' } },
        { 'name' => 'merge-discard-train', 'surface' => '§10.5/§11.6 Minor-Merge, Zug abwerfen (Zuglimit)', 'slice' => 'S2',
          'game' => 'random-4p-1', 'first' => { 'round' => 'Stock', 'step' => 'MergeDiscardTrain' } },
        { 'name' => 'phase-5', 'surface' => 'Zugphase 5 beginnt (Level-5-Zuege, Konsolidierung ausgeloest)', 'slice' => 'S3',
          'game' => 'strategy-4p-1', 'first' => { 'phase' => '5' } },
        { 'name' => 'consolidation-first', 'surface' => '§10.6 Konsolidierungsrunde (Minors und Regionals: mergen, kaufen, verkaufen)', 'slice' => 'S3',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Consolidation', 'step' => 'Consolidate' } },
        { 'name' => 'consolidation-merge-minor', 'surface' => '§10.6 Konsolidierung: Minor in den Major mergen', 'slice' => 'S3',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Consolidation', 'step' => 'MergeMinor' } },
        { 'name' => 'consolidation-merge-token', 'surface' => '§10.6 Konsolidierung: Token-Wahl nach Merge', 'slice' => 'S3',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Consolidation', 'step' => 'MergeToken' } },
        { 'name' => 'consolidation-merge-offer', 'surface' => '§10.6 Konsolidierung: Merge-Angebot an die Spieler', 'slice' => 'S3',
          'game' => 'strategy-4p-1', 'first' => { 'round' => 'Consolidation', 'step' => 'MergeOffer' } },
        { 'name' => 'consolidation-discard-train', 'surface' => '§10.6/§11.6 Konsolidierung: Zug abwerfen nach Merge (Zuglimit)', 'slice' => 'S3',
          'game' => 'strategy-3p-1', 'first' => { 'round' => 'Consolidation', 'step' => 'MergeDiscardTrain' } },
        { 'name' => 'operating-discard-train', 'surface' => '§11.6 Zuglimit: Zug abwerfen im Betrieb (Phasenwechsel)', 'slice' => 'S3',
          'game' => 'strategy-3p-1', 'first' => { 'round' => 'Operating', 'step' => 'DiscardTrain' } },
        { 'name' => 'phase-6', 'surface' => 'Zugphase 6', 'slice' => 'S3',
          'game' => 'strategy-4p-1', 'first' => { 'phase' => '6' } },
        { 'name' => 'phase-7', 'surface' => 'Zugphase 7', 'slice' => 'S3',
          'game' => 'strategy-4p-1', 'first' => { 'phase' => '7' } },
        { 'name' => 'phase-8', 'surface' => 'Zugphase 8 (Level-8-Zuege)', 'slice' => 'S3',
          'game' => 'strategy-4p-1', 'first' => { 'phase' => '8' } },
        { 'name' => 'game-end', 'surface' => '§13 Spielende (Endphase, Endstand, View ohne Betrachter)', 'slice' => 'S1',
          'game' => 'strategy-4p-1', 'first' => { 'finished' => true } },
      ],
      # Surfaces of the slice that no entry covers yet, with the reason (#117 verification).
      'gaps' => [
        { 'surface' => '§13 Spielende durch gesprengte Bank', 'slice' => 'S1',
          'reason' => 'Strategie-Partie 4p/Seed 1 endet regulaer in der Endphase (Bank 137289 am Ende, nicht gebrochen); ' \
                      'ein Bankbruch kommt in Bot-/Zufallspartien nicht vor und liesse sich nur durch Zustandsvorgabe erzeugen. ' \
                      'Regel ist als Zustands-Spec abgedeckt (spec/engine/g_18_oe/bank_break_spec.rb, #68).' },
        { 'surface' => '§8.4 Reserved Shares (Schritt ReserveShare)', 'slice' => 'S1',
          'reason' => 'In 12 Zufallspartien (3 bis 6 Spieler) und den Strategiepartien nie erreicht: nach der Concession-Runde haben ' \
                      'die Spieler zu wenig Geld fuer ein zweites Anteilskaufen in der ersten SR. Gedeckt durch den Script-Game-Lauf ' \
                      '(slice s1, Ziele stock/ReserveShare/choose:reserve und pass) und Engine-Specs; als Katalogeintrag nur mit ' \
                      'gesteuerter Partie (Handeingabe) moeglich.' },
        { 'surface' => '§10.4 Spielerhandel (Kauf von Spielern, Zustimmung des Verkaeufers)', 'slice' => 'S1',
          'reason' => 'Engine: Game#player_trade_enabled? ist false, die Regel ist nicht gespielbar; Zustimmungs-Abfrage folgt mit #148 ' \
                      '(Teil 2). Eintrag, sobald #148 den Handel freischaltet.' },
        { 'surface' => '§10.5/§11.6 Zugkauf mit Aktienverkauf des Praesidenten (BuyTrain/sell_shares)', 'slice' => 'S2',
          'reason' => 'In den Strategie- und Zufallspartien kommt sell_shares nur im Issue-Step und in der Konsolidierung vor, nie im ' \
                      'BuyTrain-Schritt (Strategie verkauft nicht fuer Zuege). Script-Game-Ziel operating/BuyTrain/sell_shares:major.' },
        { 'surface' => 'Geparrtes Regional, das niemand kauft', 'slice' => 'S2',
          'reason' => 'Kam in keiner der Partien vor; in der Engine wird der Fall durch close_unfloated_regionals_at_maximum! (#348) ' \
                      'behandelt, eigener Eintrag erst mit gesteuerter Partie.' },
        { 'surface' => 'Orient-Express-Bonus (OrientExpressBonus-Schritt), SpecialToken', 'slice' => 'S3',
          'reason' => 'Weder die Strategie-Partien 3p/4p Seed 1 (enden in Phase 8 in der Endphase) noch Zufallspartien erreichen den ' \
                      'Orient-Express-Bonus-Lauf oder einen SpecialToken-Schritt; nur Szenario-Specs. Eintrag, sobald eine Partie ihn zeigt.' },
        { 'surface' => 'Auktion mit Pass-Pass bei Preis 0 (Waterfall)', 'slice' => 'S1',
          'reason' => 'DEFEKT, kein Katalogeintrag: Zufallspartie 3 Spieler/Seed 5 wird in der Auktion mit Pass abgelehnt ' \
                      '(GameError Cannot spend zero or negative money in Spender.spend(0), Aktion 531); als eigenes Issue zu melden.' },
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
      next_type = log.first && log.first['type']
      step_state = lambda do |count|
        state = FixtureCatalog.describe(game)
        pending.dup.each do |e|
          hit = if e.key?('at') then e['at'] == count
                elsif e.key?('first') then e['first'].all? { |key, want| state[key] == want }
                else next_type == e['before']['type']
                end
          next unless hit

          positions[e['game']][e['name']] = { position: count, expect: (e['first'] || {}).merge(state.slice('round', 'step')) }
          pending.delete(e)
        end
      end
      step_state.call(0)
      log.each_with_index do |action, i|
        game.process_action(action)
        raise "replay failed at #{i + 1}: #{game.exception.message}" if game.exception

        next_type = log[i + 1] && log[i + 1]['type']
        step_state.call(i + 1)
        break if pending.empty?
      end
    end
  end
end
