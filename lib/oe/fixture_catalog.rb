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
  # The logs are built (and rebuilt after an engine change that alters play) by
  # bin/fixture-catalog; `bin/fixture-catalog verify` re-checks every entry.
  module FixtureCatalog
    Entry = Struct.new(:name, :surface, :slice, :game, :position, :expect, :note, keyword_init: true)

    DIR = File.expand_path('../../spec/fixtures/games', __dir__)

    module_function

    def catalog(dir = DIR)
      JSON.parse(File.read(File.join(dir, 'catalog.json')))
    end

    def entries(dir = DIR)
      catalog(dir)['entries'].map do |h|
        Entry.new(name: h['name'], surface: h['surface'], slice: h['slice'], game: h['game'],
                  position: h['position'], expect: h['expect'] || {}, note: h['note'])
      end
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
