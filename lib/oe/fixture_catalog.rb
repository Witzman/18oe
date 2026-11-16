# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'engine'
require_relative 'legal_actions'
require_relative 'view'

module Oe
  # Catalog of playable game states, one or more per rule surface (#117).
  #
  # A fixture is an *action log* (the accepted actions of a game of the catalog), not a view
  # snapshot. An entry names the rule surface (section of the rulebook), the slice (S1..S9) and a
  # finder (`at`, `first`, `before`, `where`, `after`) that is resolved against the log when the
  # catalog is loaded (#365), so a drifting engine or log is noticed. Several entries share one log.
  # `find(round:, step:)` picks a state by property.
  #
  #   spec/fixtures/games/catalog.json          { "games": { name => {players, seed, player, max_actions} },
  #                                               "entries": [ {name, surface, slice, game, <finder>, note} ], "gaps": [...] }
  #   spec/fixtures/games/logs/<game>.jsonl     one accepted action per line (JSON); players, seed and player
  #                                             kind are those of the game in catalog.json
  #   spec/fixtures/games/logs/manifest.json    what the logs were built with (engine SHA, actions and resolved
  #                                             positions per log); information for the refresh diff, the loader
  #                                             does not read it
  #
  # The logs are built (and rebuilt after an engine change that alters play) by
  # bin/fixture-catalog, in a catalog refresh only; `bin/fixture-catalog verify` re-checks every entry.
  #
  # Two modes (#365): `stored` (default) replays the log files; `live` (OE_CATALOG=live) plays a fresh
  # game per catalog game with Oe::Playthrough (players, seed, player kind, max_actions of the catalog)
  # and resolves the finders on that, so the current engine is checked without a rebuild. In `stored`
  # mode a log the engine no longer accepts raises StaleLog (log <game> stale at action K ...), which
  # says "refresh the catalog", as opposed to a finding in a state.
  module FixtureCatalog
    # The stored log does not fit the engine (or strategy) any more: a catalog refresh is due.
    class StaleLog < RuntimeError; end

    # `position`, `expect` and `state` of an entry are resolved on first use (a replay of the log),
    # so reading names, finders and notes costs nothing.
    Entry = Struct.new(:name, :surface, :slice, :game, :note, :finder, :resolver, :override, keyword_init: true) do
      def position = resolved[:position]
      def expect = override || resolved[:expect] || {}
      def expect=(value)
        self.override = value
      end
      def state = resolved[:state]
      def resolved = (@resolved ||= resolver.call)
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
    LOGS = 'logs'

    module_function

    def live?
      ENV['OE_CATALOG'] == 'live'
    end

    def catalog(dir = DIR)
      JSON.parse(File.read(File.join(dir, 'catalog.json')))
    end

    # Every entry is a finder, resolved against the log when first asked for its position (once per
    # process and log, see `resolutions`).
    def entries(dir = DIR)
      catalog(dir)['entries'].map do |h|
        finder = h.slice(*FINDER_KEYS)
        Entry.new(name: h['name'], surface: h['surface'], slice: h['slice'], game: h['game'], note: h['note'],
                  finder: finder.empty? ? nil : finder, resolver: -> { resolution(h, dir) })
      end
    end

    # Findings about the catalog that need no replay (empty = well formed): games, names, finders,
    # `where` names, `after` references, gaps.
    def static_errors(cat = catalog)
      errors = []
      games = cat['games'] || {}
      games.each do |name, spec|
        missing = %w[players seed].reject { |k| spec.key?(k) }
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
      errors << "#{name}: has a position (entries are finders, positions are resolved, not stored)" if entry.key?('position') || entry.key?('expect')
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
      cat['games'].fetch(game_name)
      key = [File.expand_path(dir), game_name, File.mtime(File.join(dir, 'catalog.json')), live? ? :live : File.mtime(log_path(game_name, dir))]
      (@resolutions ||= {})[key] ||= begin
        finders = cat['entries'].select { |e| e['game'] == game_name }
        scan(log_file(game_name, dir), finders, name: game_name)
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
    def scan(log, entries, actions = nil, name: nil)
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
        raise stale(name, actions, game, i + 1) if game.exception

        next_type = actions[i + 1] && actions[i + 1]['type']
        visit.call(i + 1)
      end
      found
    end

    def entry(name, dir = DIR)
      entries(dir).find { |e| e.name == name } || raise(KeyError, "no fixture entry #{name.inspect}")
    end

    # The action log of a catalog game: the stored file, or in live mode a fresh game (once per process).
    def log_file(game_name, dir = DIR)
      live? ? live_log(game_name, dir) : stored_log(game_name, dir)
    end

    # The stored log of a game: players, seed and player kind from the catalog, the actions from
    # logs/<game>.jsonl (one JSON action per line).
    def stored_log(game_name, dir = DIR)
      spec = catalog(dir)['games'].fetch(game_name)
      { 'players' => spec['players'], 'seed' => spec['seed'], 'player' => spec['player'],
        'actions_log' => File.foreach(log_path(game_name, dir)).map { |line| JSON.parse(line) } }
    end

    def log_path(game_name, dir = DIR)
      File.join(dir, LOGS, "#{game_name}.jsonl")
    end

    # One action per line, so `git diff` of a refresh shows the shared start and the first changed action.
    def write_log(game_name, actions, dir = DIR)
      FileUtils.mkdir_p(File.join(dir, LOGS))
      File.write(log_path(game_name, dir), actions.map { |a| "#{JSON.generate(a)}\n" }.join)
    end

    # A fresh game of the catalog's definition. Raises when it does not play on (engine or enumerator
    # defect), since a log cut short would make every later finder fail with a misleading message.
    def live_log(game_name, dir = DIR)
      spec = catalog(dir)['games'].fetch(game_name)
      @live_logs ||= {}
      @live_logs[[game_name, spec]] ||= begin
        result = play(spec)
        unless %i[finished limit].include?(result.status)
          raise "live game #{game_name} stopped (#{result.status}) after #{result.actions} actions: #{result.stop_point}"
        end

        { 'players' => spec['players'], 'seed' => spec['seed'], 'player' => spec['player'], 'actions_log' => result.log }
      end
    end

    # Plays the game of a catalog game spec with Oe::Playthrough (deterministic: players, seed, player kind).
    def play(spec)
      require_relative 'playthrough'
      Playthrough.run(players: spec['players'], seed: spec['seed'], max_actions: spec['max_actions'], player: spec['player'].to_sym)
    end

    # StaleLog for the action at which a replaying game refused the log (1-based; `count` defaults to the
    # game's accepted actions + 1, since the refused action was popped from game.actions).
    def stale(name, actions, game, count = game.actions.size + 1)
      refused = actions[count - 1] || {}
      StaleLog.new("log #{name || '?'} stale at action #{count} (#{refused['type']}): " \
                   "#{game.exception.class.name.split('::').last}: #{game.exception.message[0, 160]}; the catalog needs a refresh")
    end

    # First differing action (0-based) of the stored and a fresh action list (ids and times ignored), or nil
    # if the stored one is a prefix of the fresh one (a stored log is cut after its last needed position).
    def first_difference(stored, fresh)
      strip = ->(a) { a.reject { |k, _| %w[id created_at].include?(k) } }
      common = [stored.size, fresh.size].min
      (0...common).find { |i| strip.call(stored[i]) != strip.call(fresh[i]) } || (stored.size > fresh.size ? common : nil)
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
      actions = file['actions_log'].first(entry.position)
      game = new_game(file, actions)
      raise stale(entry.game, actions, game) if game.exception

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
