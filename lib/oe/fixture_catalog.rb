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
    # `position`, `expect` and `state` of an entry with a finder are resolved on first use (a replay of
    # the log), so reading names, finders and notes costs nothing.
    Entry = Struct.new(:name, :surface, :slice, :game, :position, :expect, :note, :finder, :resolver, keyword_init: true) do
      def position = self[:position] || resolved[:position]
      def expect = self[:expect] || resolved[:expect] || {}
      def state = resolved[:state]
      def resolved = (@resolved ||= resolver ? resolver.call : {})
    end

    # Finder of an entry (see Oe::FixtureBuilder): exactly one of
    #   at: 0                          the start state
    #   first: { round:, step:, phase:, finished: }   first state matching all given keys
    #   before: { type: }              the state just before the first logged action of that type
    # and, on top, any of
    #   where: <name>                  also the named predicate of WHERE holds (a lambda on the game)
    #   after: <entry name>            only states behind the position of that earlier entry (same game)
    PRIMARY_FINDERS = %w[at first before].freeze
    FINDER_KEYS = (PRIMARY_FINDERS + %w[where after]).freeze
    FIRST_KEYS = %w[round step phase finished].freeze

    # Named predicates for `where`. A new one is a small lambda here, not a new engine class.
    WHERE = {
      # Companies of the waterfall auction carry bids (the auction step's own table, Auctioner#bids).
      'bids_open' => lambda { |game|
        step = game.round.active_step
        step.respond_to?(:bids) && step.bids.values.any? { |bids| !bids.empty? }
      },
    }.freeze

    DIR = File.expand_path('../../spec/fixtures/games', __dir__)

    module_function

    def catalog(dir = DIR)
      JSON.parse(File.read(File.join(dir, 'catalog.json')))
    end

    # Two formats are read (#365): an entry with `position` (and `expect`) is taken as stored; an
    # entry with a finder and no position is resolved against the log when first asked for its
    # position (once per process and log, see `resolutions`).
    def entries(dir = DIR)
      catalog(dir)['entries'].map do |h|
        finder = h.slice(*FINDER_KEYS)
        Entry.new(name: h['name'], surface: h['surface'], slice: h['slice'], game: h['game'],
                  position: h['position'], expect: h['expect'], note: h['note'],
                  finder: finder.empty? ? nil : finder,
                  resolver: h.key?('position') ? nil : -> { resolution(h, dir) })
      end
    end

    # Findings about the catalog that need no replay (empty = well formed): games, names, finders,
    # `where` names, `after` references, gaps.
    def static_errors(cat = catalog)
      errors = []
      games = cat['games'] || {}
      games.each do |name, spec|
        missing = %w[file players seed].reject { |k| spec.key?(k) }
        errors << "game #{name}: no #{missing.join(', ')}" unless missing.empty?
        errors << "game #{name}: player must be strategy or random" unless %w[strategy random].include?(spec['player'])
        errors << "game #{name}: max_actions missing" unless spec['max_actions'].is_a?(Integer)
      end
      seen = []
      (cat['entries'] || []).each do |e|
        name = e['name']
        errors << "entry #{name.inspect}: name missing or twice" if name.to_s.empty? || seen.include?(name)
        errors << "#{name}: unknown game #{e['game'].inspect}" unless games.key?(e['game'])
        errors << "#{name}: no surface" if e['surface'].to_s.empty?
        errors << "#{name}: slice must be S1..S9" unless e['slice'].to_s.match?(/\AS[1-9]\z/)
        errors.concat(finder_errors(e, seen, cat['entries']))
        seen << name
      end
      (cat['gaps'] || []).each { |gap| errors << "gap #{gap['surface'].inspect}: no reason" if gap['reason'].to_s.empty? }
      errors
    end

    def finder_errors(entry, earlier, all)
      name = entry['name']
      errors = []
      primary = entry.keys & PRIMARY_FINDERS
      errors << "#{name}: needs exactly one of #{PRIMARY_FINDERS.join('/')} (has #{primary.inspect})" unless primary.size == 1
      errors << "#{name}: at must be 0" if entry.key?('at') && entry['at'] != 0
      if entry.key?('first')
        unknown = entry['first'].is_a?(Hash) ? entry['first'].keys - FIRST_KEYS : ['not a hash']
        errors << "#{name}: first has unknown keys #{unknown.inspect}" unless unknown.empty?
        errors << "#{name}: first is empty" if entry['first'] == {}
      end
      errors << "#{name}: before needs a type" if entry.key?('before') && entry['before'].to_h['type'].to_s.empty?
      errors << "#{name}: unknown where #{entry['where'].inspect}" if entry.key?('where') && !WHERE.key?(entry['where'])
      if entry.key?('after')
        ref = all.find { |o| o['name'] == entry['after'] }
        errors << "#{name}: after #{entry['after'].inspect} is not an earlier entry of the same game" unless
          ref && earlier.include?(ref['name']) && ref['game'] == entry['game']
      end
      errors << "#{name}: has a position (finder entries are resolved, not stored)" if entry.key?('position') && !(entry.keys & FINDER_KEYS).empty?
      errors
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
      # The start state needs no replay.
      if hash['at'] == 0 && !hash.key?('after') && !hash.key?('where')
        key = [File.expand_path(dir), :start, hash['game'], File.mtime(File.join(dir, 'catalog.json'))]
        return ((@resolutions ||= {})[key] ||= scan(catalog(dir)['games'].fetch(hash['game']), [hash], []))[hash['name']]
      end

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

    def behind?(entry, found, count)
      return true unless entry.key?('after')

      earlier = found[entry['after']]
      !earlier.nil? && count > earlier[:position]
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
          next unless hit && behind?(e, found, count) && (!e.key?('where') || WHERE.fetch(e['where']).call(game))

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
