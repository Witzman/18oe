# frozen_string_literal: true

require 'json'
require 'engine'
require_relative 'legal_actions'
require_relative 'view'

module Oe
  # Catalog of playable game states, one or more per rule surface (#117).
  #
  # A fixture is an *action log* (what bin/playthrough writes: players, seed, accepted
  # actions), not a view snapshot. An entry names a position in such a log (number of
  # actions applied), the rule surface (section of the rulebook), the slice (S1..S9) and
  # what the engine must say at that position (`expect`: round class and active step), so
  # a drifting engine or log is noticed. Several entries may share one log.
  #
  #   spec/fixtures/games/catalog.json   { "games": { name => {file, players, seed} },
  #                                        "entries": [ {name, surface, slice, game, position, expect, note} ] }
  #   spec/fixtures/games/<game>.json    { players, seed, player, actions_log: [...] }
  #
  # An entry holds either a stored `position` and `expect` (today's catalog.json) or a finder
  # (`at`, `first`, `before`, as in Oe::FixtureBuilder), which is resolved against the log when the
  # catalog is loaded (#365). `find(round:, step:)` picks a state by property.
  #
  # The logs are built (and rebuilt after an engine change that alters play) by
  # bin/fixture-catalog; `bin/fixture-catalog verify` re-checks every entry.
  module FixtureCatalog
    Entry = Struct.new(:name, :surface, :slice, :game, :position, :expect, :note, :finder, :state, keyword_init: true)

    # Finder keys of an entry (see Oe::FixtureBuilder): a fixed position, the first state matching
    # given keys, or the state just before the first logged action of a type.
    FINDER_KEYS = %w[at first before].freeze

    DIR = File.expand_path('../../spec/fixtures/games', __dir__)

    module_function

    def catalog(dir = DIR)
      JSON.parse(File.read(File.join(dir, 'catalog.json')))
    end

    # Two formats are read (#365): an entry with `position` (and `expect`) is taken as stored; an
    # entry with a finder (`at`, `first` or `before`) and no position is resolved against the log
    # when loaded (once per process and log, see `resolutions`).
    def entries(dir = DIR)
      catalog(dir)['entries'].map do |h|
        finder = h.slice(*FINDER_KEYS)
        found = h.key?('position') ? nil : resolution(h, dir)
        Entry.new(name: h['name'], surface: h['surface'], slice: h['slice'], game: h['game'],
                  position: h['position'] || found[:position], expect: h['expect'] || found[:expect], note: h['note'],
                  finder: finder.empty? ? nil : finder, state: found && found[:state])
      end
    end

    # Any catalog state in the given round/step (and phase): the first entry, in catalog order,
    # whose state matches. Specs ask by property instead of by entry name. Nil if none.
    def find(round: nil, step: nil, phase: nil, dir: DIR)
      want = { 'round' => round, 'step' => step, 'phase' => phase&.to_s }.compact
      entries(dir).find do |e|
        state = e.state || describe(game_at(e, dir))
        want.all? { |key, value| state[key] == value }
      end
    end

    def game(name, dir = DIR)
      game_at(name, dir)
    end

    # name => { position:, expect:, state: } for the finder entries of the catalog, memoised per
    # catalog, log file and their modification times.
    def resolution(hash, dir)
      resolutions(dir, hash['game']).fetch(hash['name']) do
        raise "finder #{hash['name']} matched nothing in #{hash['game']} (#{log_file(hash['game'], dir)['actions_log'].size} actions)"
      end
    end

    def resolutions(dir, game_name)
      cat = catalog(dir)
      file = File.join(dir, cat['games'].fetch(game_name)['file'])
      key = [File.expand_path(dir), game_name, File.mtime(File.join(dir, 'catalog.json')), File.mtime(file)]
      (@resolutions ||= {})[key] ||= begin
        log = JSON.parse(File.read(file))
        finders = cat['entries'].select { |e| e['game'] == game_name && !e.key?('position') }
        scan(log, finders)
      end
    end

    # Replays `log` once and finds, for each entry hash with a finder, the first position that
    # satisfies it. Returns name => { position:, expect:, state: } (entries never matched are absent).
    # `log` is anything with `players` and `seed` (a log file hash, or a game spec of the builder
    # when the action list is passed as `actions`). The finder semantics are the builder's.
    def scan(log, entries, actions = nil)
      actions ||= log['actions_log']
      found = {}
      pending = entries.dup
      game = Engine::Game::G18OE::Game.new(("A".."Z").first(log['players']), id: log['seed'], seed: log['seed'])
      next_type = actions.first && actions.first['type']
      visit = lambda do |count|
        state = describe(game)
        pending.dup.each do |e|
          hit = if e.key?('at') then e['at'] == count
                elsif e.key?('first') then e['first'].all? { |key, want| state[key] == want }
                else next_type == e['before']['type']
                end
          next unless hit

          found[e['name']] = { position: count, expect: (e['first'] || {}).merge(state.slice('round', 'step')), state: state }
          pending.delete(e)
        end
      end
      visit.call(0)
      actions.each_with_index do |action, i|
        break if pending.empty?

        game.process_action(action)
        raise "replay failed at #{i + 1}: #{game.exception.message}" if game.exception

        next_type = actions[i + 1] && actions[i + 1]['type']
        visit.call(i + 1)
      end
      found
    end

    def entry(name, dir = DIR)
      entries(dir).find { |e| e.name == name } || raise(KeyError, "no fixture entry #{name.inspect}")
    end

    def log_file(game_name, dir = DIR)
      JSON.parse(File.read(File.join(dir, catalog(dir)['games'].fetch(game_name)['file'])))
    end

    def new_game(file, actions)
      Engine::Game::G18OE::Game.new(("A".."Z").first(file['players']), id: file['seed'], seed: file['seed'],
                                                                      actions: actions)
    end

    # The game at an entry's position, replayed from a fresh start. `file` may be passed
    # to avoid re-reading the log.
    def game_at(entry, dir = DIR, file: nil)
      entry = entry(entry, dir) if entry.is_a?(String)
      file ||= log_file(entry.game, dir)
      game = new_game(file, file['actions_log'].first(entry.position))
      raise "fixture #{entry.name}: engine rejected the log: #{game.exception.message}" if game.exception

      game
    end

    # What the engine says about a state, in the vocabulary of `expect`.
    def describe(game)
      step = game.round.active_step
      { 'round' => game.round.class.name.split('::').last,
        'step' => step&.class&.name&.split('::')&.last,
        'phase' => game.phase.name.to_s,
        'finished' => game.finished ? true : false }
    end

    # Differences between the catalog's expectation and the game; empty when it matches.
    def expectation_errors(entry, game)
      actual = describe(game)
      entry.expect.reject { |key, want| actual[key] == want }
           .map { |key, want| "#{entry.name}: expected #{key}=#{want.inspect}, got #{actual[key].inspect}" }
    end

    # Which offered actions to try on a copy: all if few, else every class once plus a
    # seeded sample (the families of prices are large; see Oe::Playthrough).
    def sample_actions(actions, max: 10, seed: 1)
      return actions if actions.size <= max

      rng = Random.new(seed)
      firsts = actions.group_by(&:class).values.map { |same| same.sample(random: rng) }.first(max)
      (firsts + (actions - firsts).sample(max - firsts.size, random: rng)).first(max)
    end

    # The full check of one entry. Returns a Hash of findings (all arrays; empty = ok):
    #   expectation  catalog expectation not met
    #   view         View.render raised, or is not JSON-clean
    #   enumerate    LegalActions raised, or offered nothing in an unfinished game
    #   rejected     an offered action the engine refused on a copy
    def check(entry, dir = DIR, file: nil, game: nil, max_actions: 10)
      entry = entry(entry, dir) if entry.is_a?(String)
      file ||= log_file(entry.game, dir)
      game ||= game_at(entry, dir, file: file)
      findings = { 'expectation' => expectation_errors(entry, game), 'view' => [], 'enumerate' => [], 'rejected' => [] }

      begin
        view = View.render(game, viewer: game.finished ? nil : game.active_players.first&.id)
        again = JSON.parse(JSON.generate(view))
        findings['view'] << 'view lost data in JSON' unless again.is_a?(Hash) && again.keys.size == view.keys.size
      rescue StandardError => e
        findings['view'] << "#{e.class}: #{e.message[0, 160]}"
      end

      actions = []
      begin
        actions = LegalActions.new(game, limit: 12, rng: Random.new(1)).call
        findings['enumerate'] << 'no legal action offered' if actions.empty? && !game.finished
      rescue StandardError => e
        findings['enumerate'] << "#{e.class}: #{e.message[0, 160]}"
      end

      prefix = file['actions_log'].first(entry.position)
      sample_actions(actions, max: max_actions).each do |action|
        copy = new_game(file, prefix)
        # The enumerator's actions point at entities of `game`; the copy takes the hash form.
        copy.process_action(action.to_h)
        next unless (error = copy.exception)

        findings['rejected'] << "#{action.class.name.split('::').last}: #{error.class}: #{error.message[0, 120]}"
      end
      findings
    end

    def problems(findings)
      findings.flat_map { |kind, list| list.map { |text| "#{kind}: #{text}" } }
    end
  end
end
