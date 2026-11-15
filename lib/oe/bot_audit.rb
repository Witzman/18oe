# frozen_string_literal: true

require "json"
require_relative "bot"

module Oe
  # Bot game audit (#306): plays bots-only tables with a fixed seed and measures
  # what happens, without judging rules. Three outputs:
  #   progress   rounds/steps, actions per minute, time per step, stalls (#289)
  #   actions    per step: how often it was offered, which action classes were
  #              legal, which one the bot chose, how often only "pass" came (#293)
  #   invariants checked after every action (see Invariants)
  # A finding is a plain hash; nothing here changes the game.
  class BotAudit
    # Checks on a game state. Each returns a list of finding strings (empty = ok).
    # `Oe::BotAudit::Invariants.check(game, baseline)` is pure and testable.
    module Invariants
      module_function

      # Everything that holds cash: players, corporations (incl. minors), bank.
      def total_cash(game)
        entities = game.players + (game.corporations + game.minors).uniq
        entities.sum(&:cash) + game.bank.cash
      end

      def check(game, baseline_cash)
        out = []
        total = total_cash(game)
        out << "cash total #{total} != baseline #{baseline_cash}" if total != baseline_cash
        game.players.each do |p|
          out << "#{p.name} cash #{p.cash} < 0" if p.cash.negative? && !bankrupt?(game, p)
          limit = game.cert_limit(p)
          certs = game.num_certs(p)
          out << "#{p.name} certs #{certs} > limit #{limit}" if certs > limit
        end
        (game.corporations + game.minors).uniq.each do |c|
          out << "#{c.name} cash #{c.cash} < 0" if c.cash.negative?
          next unless c.ipoed

          sum = c.share_holders.values.sum
          out << "#{c.name} shares sum #{sum}% != 100%" if sum != 100
        end
        out
      end

      def bankrupt?(game, player)
        game.respond_to?(:bankrupt) && game.bankrupt == player
      end
    end

    Result = Struct.new(:seed, :players, :status, :actions, :seconds, :turn, :findings, :steps, :stalls,
                        :slowest, :opening, keyword_init: true) do
      def to_h = super.transform_keys(&:to_s)
    end

    def self.run(**opts) = new(**opts).run

    # stall_after: identical (state fingerprint) repeated this many times = loop.
    # valuation/profile: passed to Oe::Bot (#313). stop_at: :phase3 ends the run when
    # train phase 3 begins (the opening measurement does not need a whole game).
    def initialize(players:, seed:, max_actions: 20_000, limit: 12, stall_after: 25, max_findings: 50, log: nil,
                   valuation: :derived, profile: :standard, stop_at: nil)
      @valuation = valuation
      @profile = profile
      @stop_at = stop_at
      @players = players
      @seed = seed
      @max_actions = max_actions
      @limit = limit
      @stall_after = stall_after
      @max_findings = max_findings
      @log = log # IO for one JSON line per action
    end

    def run
      ids = (0...@players).map { |i| "p#{i}" }
      game = Engine::Game::G18OE::Game.new(ids, id: @seed, seed: @seed)
      bot = Oe::Bot.new(game, rng: Random.new(@seed), limit: @limit, valuation: @valuation, profile: @profile)
      opening = Opening.new(game)
      baseline = Invariants.total_cash(game)
      steps = Hash.new { |h, k| h[k] = { offered: 0, only_pass: 0, visits: 0, visits_with_choice: 0, visits_skipped: 0, chosen: Hash.new(0), legal: Hash.new(0), seconds: 0.0, max: 0.0 } }
      findings = []
      seen = Hash.new(0)
      slowest = []
      stalls = 0
      last_visit = nil
      last_visit_key = nil
      last_visit_state = nil
      status = :limit
      count = 0
      started = now

      while count < @max_actions
        (status = :finished; break) if game.finished
        (status = :phase3; break) if @stop_at == :phase3 && opening.phase3

        t0 = now
        game_turn_before = game.turn
        entity_before = game.round.respond_to?(:current_entity) ? game.round.current_entity&.id : nil
        pid = nil
        actions = nil
        game.active_players.each do |pl|
          a = bot.legal_actions(pl.id)
          next if a.empty?

          pid = pl.id
          actions = a
          break
        end
        unless pid
          status = :dead_end
          findings << finding(:hang, "dead end: no legal action for #{game.active_players.map(&:id)}", game, count)
          break
        end

        key = step_key(game)
        legal = actions.map { |a| short(a) }.tally
        action = bot.choose(player_id: pid)
        game.process_action(action)
        dt = now - t0
        if game.exception
          status = :rejected
          findings << finding(:rejected, "#{short(action)}: #{game.exception.message[0, 160]}", game, count)
          break
        end
        # The enumerated set is sampled (limit) and bids are ranges, so compare the action
        # *type* with what the step offered; a wrong value is caught by game.exception above.
        unless legal.key?(short(action))
          findings << finding(:not_legal, "chosen #{short(action)} not among legal types #{legal.keys}", game, count)
        end

        s = steps[key]
        # A visit = one entity in one step during one turn (several actions possible, e.g. tile + pass).
        visit = [game_turn_before, key, entity_before]
        if visit != last_visit
          close_visit(steps, last_visit_key, last_visit_state)
          last_visit = visit
          last_visit_key = key
          last_visit_state = { choice: false, took: false }
          s[:visits] += 1
        end
        non_pass = legal.keys.any? { |k| k != "Pass" }
        last_visit_state[:choice] ||= non_pass
        last_visit_state[:took] ||= short(action) != "Pass"
        s[:offered] += 1
        s[:only_pass] += 1 if legal.keys.all? { |k| k == "Pass" }
        s[:chosen][short(action)] += 1
        legal.each_key { |k| s[:legal][k] += 1 }
        s[:seconds] += dt
        s[:max] = dt if dt > s[:max]
        slowest << [dt, key, count]
        slowest = slowest.max_by(10, &:first) if slowest.size > 40
        count += 1
        opening.observe(count)
        @log&.puts(JSON.generate(n: count, step: key, player: pid, legal: legal, chosen: short(action), sec: dt.round(4)))

        Invariants.check(game, baseline).each do |msg|
          # events inject cash into the bank (remainder); rebase once, report once
          if msg.start_with?("cash total") && game.log.last(5).any? { |l| l.message.to_s.include?("remainder cash") }
            baseline = Invariants.total_cash(game)
            next
          end
          next if seen[msg.sub(/\d+/, "N")] >= 3
          seen[msg.sub(/\d+/, "N")] += 1
          findings << finding(:invariant, msg, game, count) if findings.size < @max_findings
        end

        fp = [game.turn, key, game.players.map(&:cash), action.to_h].hash
        seen[fp] += 1
        if seen[fp] == @stall_after
          stalls += 1
          findings << finding(:hang, "state repeated #{@stall_after}x (loop) at #{key}", game, count)
          status = :stalled
          break
        end
      end

      close_visit(steps, last_visit_key, last_visit_state)
      Result.new(seed: @seed, players: @players, status: status, actions: count, seconds: now - started,
                 turn: game.turn, findings: findings, stalls: stalls, opening: opening.to_h,
                 slowest: slowest.sort_by { |x| -x[0] }.first(5).map { |dt, k, n| { "sec" => dt.round(3), "step" => k, "n" => n } },
                 steps: steps.transform_values do |v|
                   v.merge(seconds: v[:seconds].round(3), max: v[:max].round(3), chosen: v[:chosen].dup, legal: v[:legal].dup)
                 end)
    end

    # The opening (#313): who got which private/minor at what price, what was
    # floated before the first operating round, and when train phase 3 began
    # (the first level-3 train; goal of every player, #140).
    class Opening
      attr_reader :phase3

      def initialize(game)
        @game = game
        @start_cash = game.players.to_h { |p| [p.id, p.cash] }
        @auction = nil
        @first_or = nil
        @phase3 = nil
      end

      def observe(count)
        round = @game.round
        @auction ||= snapshot_auction(count) unless round.is_a?(Engine::Round::Auction)
        @first_or ||= snapshot_first_or(count) if round.operating?
        @phase3 ||= { "action" => count, "turn" => @game.turn, "round" => round_name(round) } if @game.phase.name.to_s >= "3"
      end

      def to_h
        { "auction" => @auction, "first_or" => @first_or, "phase3" => @phase3 }
      end

      private

      def snapshot_auction(count)
        players = @game.players.to_h do |p|
          companies = p.companies.reject { |c| c.type == :concession }
          minors, privates = companies.partition { |c| @game.company_becomes_minor?(c) }
          [p.id, { "privates" => privates.map(&:sym), "minors" => minors.map(&:sym),
                   "face" => companies.sum(&:value), "spent" => @start_cash[p.id] - p.cash, "cash" => p.cash }]
        end
        { "action" => count, "players" => players }
      end

      def snapshot_first_or(count)
        floated = @game.corporations.select(&:floated?)
        parred = @game.corporations.select do |c|
          c.ipoed && c.presidents_share&.owner == @game.share_pool
        end
        { "action" => count, "minors" => floated.count { |c| c.type == :minor },
          "regionals" => floated.count { |c| c.type != :minor && c.type != :national },
          "parred_to_market" => parred.map(&:id), "cash" => @game.players.to_h { |p| [p.id, p.cash] } }
      end

      def round_name(round)
        round.operating? ? "OR #{@game.turn}.#{round.round_num}" : "#{round.class.name.split('::').last} #{@game.turn}"
      end
    end

    private

    # A visit that offered a real choice but ended with only passes = skipped step (#293).
    def close_visit(steps, key, state)
      return unless key && state

      steps[key][:visits_with_choice] += 1 if state[:choice]
      steps[key][:visits_skipped] += 1 if state[:choice] && !state[:took]
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def step_key(game)
      "#{game.round.class.name.split('::').last}/#{game.round.active_step&.class&.name&.split('::')&.last}"
    end

    def short(action) = action.class.name.split("::").last

    def finding(kind, msg, game, count)
      { "kind" => kind.to_s, "message" => msg, "turn" => game.turn, "phase" => game.phase.name.to_s,
        "step" => step_key(game), "action_no" => count }
    end
  end
end
