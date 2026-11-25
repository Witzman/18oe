# frozen_string_literal: true

require "json"
require "yaml"
require "engine"
require_relative "bot"
require_relative "game_session"
require_relative "script_game/clients"
require_relative "script_game/report"

module Oe
  # A scripted game over the real HTTP API (#132): the seats are all humans,
  # every move is a POST /games/:id/actions of the account on turn, taken from
  # that account's own view (`prompt.actions`, `prompt.ranges`). The script
  # keeps a private mirror of the game (same seed, same actions) so it can ask
  # Oe::Bot what a sensible player would do; the move is only submitted if the
  # server offered it in the prompt, so the run also checks that the API view
  # lists what the engine accepts.
  #
  # A "director" overrides the bot while the slice's target list (SLICE file,
  # lib/oe/script_game/slices/*.yml) still has combinations of
  # round/step/action type missing: whenever one of them is on offer it is
  # played. The run fails if a combination is never executed, if a legal move
  # is rejected, if a prompt is empty although it is somebody's turn, or if
  # the game does not end regularly.
  #
  # Keys: "round/Step/type", for `choose` "round/Step/choose:<choice>" (FormNational: "choose:convert" for any
  # corporation, "choose:done" for declining).
  class ScriptGame
    SLICE_DIR = File.join(__dir__, "script_game", "slices")

    Problem = Struct.new(:kind, :detail, keyword_init: true)

    # What the run saw. `executed` counts accepted actions by key, `offered`
    # what prompts listed (so "offered but never executed" is visible).
    class Ledger
      attr_reader :executed, :offered, :problems, :get_seconds, :get_details, :post_seconds, :action_counts, :range_counts, :bytes

      def initialize
        @executed = Hash.new(0)
        @offered = Hash.new(0)
        @problems = []
        @get_seconds = []
        @get_details = [] # per GET: {index:, seconds:, round:, step:, viewer:} (#371), same order as get_seconds
        @post_seconds = []
        @action_counts = []
        @range_counts = []
        @bytes = []
      end

      def problem(kind, detail)
        @problems << Problem.new(kind: kind, detail: detail)
      end
    end

    Result = Struct.new(:slice, :status, :actions, :seed, :game_id, :ledger, :missing, :finished, :standings,
                        :seconds, :detail, :targets, :phase, :end_reason, :bank_cash, keyword_init: true) do
      def ok?
        %i[finished covered].include?(status) && missing.empty? && ledger.problems.empty?
      end
    end

    def self.slice(name)
      YAML.load_file(File.join(SLICE_DIR, "#{name.to_s.downcase}.yml"))
    end

    # clients: {account_id => client}, in seat order; the first creates the game.
    # game: index into the slice's `games` (each: name, seed, finish, rush, combos).
    def initialize(clients:, slice: "s1", game: 0, seed: nil, max_actions: 20_000, log: nil)
      @clients = clients
      @slice = self.class.slice(slice)
      @slice_name = @slice.fetch("slice")
      definition = @slice.fetch("games").fetch(game)
      @game_name = definition.fetch("name")
      @targets = definition.fetch("combos")
      @finish = definition.fetch("finish")
      @rush = definition["rush"]
      seed ||= definition.fetch("seed")
      @seed = seed
      @max_actions = max_actions
      @log = log
      @ledger = Ledger.new
      @rng = Random.new(seed)
    end

    # "round/Step/type", refined by what the action is about: the choice of a
    # `choose`, the corporation type (minor/regional/...) of par, buy_shares and
    # sell_shares.
    def key(round, step, action)
      type = action["type"]
      detail = case type
               when "choose" then step == "FormNational" && action["choice"] != "done" ? "convert" : action["choice"]
               when "par" then corporation_type(action["corporation"])
               when "buy_company" then "trade" if trade_offer?(action)
               when "buy_shares", "sell_shares" then corporation_type(action["shares"].first.sub(/_\d+\z/, ""))
               end
      "#{round}/#{step}/#{[type, detail].compact.join(':')}"
    end

    # A buy_company of another player's company is a trade offer (§10.4, #202), told apart from the
    # purchase of a bank-owned private: in the prompt it is a range (price from min to max); as a
    # plain action it is one when the mirror shows a player as the owner.
    def trade_offer?(action)
      return true if action.key?("min")

      owner = @mirror&.company_by_id(action["company"])&.owner
      owner.respond_to?(:player?) && owner.player? ? true : false
    end

    def corporation_type(id)
      @mirror.corporation_by_id(id)&.type
    end

    attr_reader :game_name

    def self.games(slice)
      slice(slice).fetch("games").size
    end

    # Seats of a game of the slice (`players:` in the slice file, 4 without it, #481).
    def self.players(slice, game)
      slice(slice).fetch("games").fetch(game)["players"] || 4
    end

    def run
      started = clock
      accounts = @clients.keys
      seats = accounts.map { |a| { kind: "human", account_id: a } }
      status, game = @clients.values.first.call(:post, "/games", { seats: seats, seed: @seed })[0, 2]
      return abort_result(:create_failed, "POST /games #{status}: #{game.inspect[0, 200]}", started) unless status == 201

      @game_id = game["id"]
      @mirror = Engine::Game::G18OE::Game.new(GameSession.player_names(game["seats"]), id: @game_id, seed: @seed)
      @bot = Bot.new(@mirror, rng: @rng)
      @account_of = game["seats"].to_h { |s| [GameSession.player_id(s), s["account_id"]] }
      state = game
      last = state
      count = 0
      status = :limit

      while count < @max_actions
        if state["state"]["meta"]["finished"]
          status = :finished
          break
        end
        if !@finish && (@targets - @ledger.executed.keys).empty?
          status = :covered
          break
        end
        pid = state["state"]["meta"]["active_players"].first
        state = view_for(pid, state)
        if state.is_a?(Symbol)
          status = state
          state = last
          break
        end
        last = state
        result = step_once(pid, state)
        if result.is_a?(Symbol)
          status = result
          break
        end
        state = last = result
        count += 1
      end

      finish(status, count, state, started)
    end

    private

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def client_for(pid)
      @clients.fetch(@account_of.fetch(pid))
    end

    # The POST answer is the poster's view; reuse it when the next player is the same one.
    def view_for(pid, state)
      return record_view(state) if state["viewer"] == pid && state["_fresh"]

      status, body, took = request(pid, :get, "/games/#{@game_id}", nil,
                                   "#{state.dig('state', 'meta', 'round', 'type')}/#{state.dig('state', 'prompt', 'step')}")
      return status if status.is_a?(Symbol)

      @ledger.get_seconds << took
      @ledger.get_details << { index: @ledger.get_seconds.size - 1, seconds: took, viewer: pid, round: state.dig("state", "meta", "round", "type"),
                               step: state.dig("state", "prompt", "step"), game: @game_id }
      unless status == 200
        @ledger.problem(:get_failed, "GET /games/#{@game_id} as #{pid}: #{status}")
        return state
      end
      record_view(body.merge("_fresh" => true))
    end

    def record_view(body)
      return body if body["_counted"]

      prompt = body["state"]["prompt"]
      @ledger.action_counts << prompt["actions"].size
      @ledger.range_counts << prompt["ranges"].size
      @ledger.bytes << JSON.generate(prompt).bytesize
      body["_counted"] = true
      body
    end

    # Plays one move; returns the new state (the POST answer) or a status symbol.
    def step_once(pid, state)
      view = state["state"]
      round = view["meta"]["round"]["type"]
      prompt = view["prompt"]
      step = prompt["step"]
      unless prompt["viewer_to_act"] && (!prompt["actions"].empty? || !prompt["ranges"].empty?)
        @ledger.problem(:dead_end, "#{round}/#{step}: #{pid} is on turn but the prompt offers nothing (types #{prompt['types']})")
        return :dead_end
      end

      offered = prompt["actions"].map { |a| key(round, step, a) } +
                prompt["ranges"].map { |r| key(round, step, r) }
      offered.uniq.each { |k| @ledger.offered[k] += 1 }

      action = director(round, step, prompt) || bot_move(pid, prompt)
      unless action
        @ledger.problem(:no_move, "#{round}/#{step}: bot found no move for #{pid}")
        return :no_move
      end
      unless offered_in?(action, prompt)
        @ledger.problem(:not_offered, "#{round}/#{step}: #{action.to_json[0, 200]} is not in prompt.actions/ranges")
      end

      post(pid, state, action, round, step)
    end

    # Take a missing target when one is on offer. Some targets need a state a
    # normal game never reaches on its own (see #rush?, #starve_presidents);
    # the director then steers towards it first.
    def director(round, step, prompt)
      missing = @targets - @ledger.executed.keys
      return nil if missing.empty?

      if @rush && rush?(missing)
        pars = prompt["actions"].select { |a| a["type"] == "par" }
        return pars.min_by { |a| a["share_price"].to_i } unless pars.empty?
      end

      if @rush && missing.any? { |k| k.start_with?("stock/ReserveShare/") }
        fitting = reservable(prompt["actions"].select { |a| a["type"] == "buy_shares" })
        return fitting.sample(random: @rng) unless fitting.empty? || !reserve_question?(fitting.first)
      end

      candidates = prompt["actions"].select { |a| missing.include?(key(round, step, a)) }
      # In the order of the target list: e.g. reserve before decline, so the
      # first reservation question is answered with "reserve", the next with "pass".
      unless candidates.empty?
        first = candidates.map { |a| missing.index(key(round, step, a)) }.min
        best = candidates.select { |a| missing.index(key(round, step, a)) == first }
        return reservable(best).sample(random: @rng)
      end

      merge = start_merge(round, step, prompt, missing)
      return merge if merge

      starve = starve_presidents(round, step, prompt, missing)
      return starve if starve

      held = hold_regional(round, step, prompt, missing)
      return held if held

      crowd = crowd_trains(round, step, prompt, missing)
      return crowd if crowd

      spare = spare_bank(round, step, prompt, missing)
      return spare if spare

      range = prompt["ranges"].find { |r| missing.include?(key(round, step, r)) }
      return nil unless range

      return trade_offer_from(range) if %w[buy_company buy_corporation].include?(range["type"])

      { "type" => "bid", "entity" => range["entity"], "entity_type" => "player",
        "company" => range["company"], "price" => range["min"] }
    end

    # The offer of a trade range (§10.4, #223): a small price inside the range, so the buyer can pay.
    def trade_offer_from(range)
      price = [[5, range["min"]].max, range["max"]].min
      action = { "type" => range["type"], "entity" => range["entity"], "entity_type" => "player", "price" => price }
      action.merge(range["type"] == "buy_company" ? { "company" => range["company"] } : { "corporation" => range["company"] })
    end

    # Buying a regional's treasury shares (and so the reserved-share question,
    # §8.4, which exists only in the Initial SR) is off sale until the Major
    # Railroad Phase starts, i.e. until all 18 regionals and all 12 minors are
    # floated. In the Initial SR that happens only if everybody floats as much
    # as they can, so while such a target is missing the director pars first.
    def rush?(missing)
      @mirror.turn == 1 && !@mirror.major_phase? && missing.any? { |k| k.start_with?("stock/ReserveShare/") || k.include?("buy_shares:regional") }
    end

    # A purchase by another player of a regional whose president could still
    # reserve a share is what raises the reservation question (§8.4).
    def reservable(actions)
      return actions unless @rush

      fitting = actions.select do |a|
        next false unless a["type"] == "buy_shares"

        corporation = @mirror.corporation_by_id(a["shares"].first.sub(/_\d+\z/, ""))
        corporation.owner && corporation.owner.id != a["entity"] && @mirror.can_reserve_regional?(corporation.owner, corporation)
      end
      fitting.empty? ? actions : fitting
    end

    # §11.6.4 (`bankrupt`, the conversion into a national) needs a major
    # without a train whose treasury and president together cannot pay the
    # cheapest train. With the bot's dividends the presidents collect income
    # and the state comes only by chance; after #71 (Minor D, a new bot move)
    # changed the seeded course it no longer came at all (#434). While the
    # target is missing the director starves the presidents instead: majors
    # withhold (no dividend income for anyone) and issue no shares (no fresh
    # treasury cash); the bot then spends the treasury on its dearest
    # affordable train, and when trains rust a major is left without a train
    # and without the money for one. Both moves are legal and on offer.
    # (Full payout was tried first: it leaves the treasuries empty but makes
    # the presidents rich, and the target stayed missing in 2600 actions.)
    BANKRUPT_TARGET = "operating/BuyTrain/choose:national"

    def starve_presidents(round, step, prompt, missing)
      return nil unless round == "operating" && missing.include?(BANKRUPT_TARGET)

      wanted = case step
               when "Dividend" then ->(a) { a["type"] == "dividend" && a["kind"] == "withhold" }
               when "IssueShares" then ->(a) { a["type"] == "pass" }
               else return nil
               end
      prompt["actions"].find { |a| wanted.call(a) && corporation_type(a["entity"]) == :major }
    end

    # A merge the president makes himself starts with a choice of the minor's id (no target; the choices with a
    # target are the offers). It is no target of its own (its key carries the id), so the bot takes it only by
    # chance; while the merge step's action is missing the director chooses a minor (#481).
    MERGE_TARGET = "stock/MergeMinor/merge"

    def start_merge(round, step, prompt, missing)
      return nil unless round == "stock" && step == "BuySellParShares" && missing.include?(MERGE_TARGET)

      prompt["actions"].find { |a| a["type"] == "choose" && !a["target"] && corporation_type(a["choice"]) == :minor }
    end

    # The Consolidation round offers `convert` only to the president of a regional that is still there (#492). The
    # strategy converts every regional at the first chance, so none is left and the target stays missing. While it
    # is missing the director keeps ONE regional (the first one a convert is offered for) unconverted in the Stock
    # Rounds: it converts the others and passes when only the held one is left. Everything else is the bot's play.
    CONSOLIDATION_CONVERT = "consolidation/Consolidate/convert"

    def hold_regional(round, step, prompt, missing)
      return nil unless round == "stock" && missing.include?(CONSOLIDATION_CONVERT)

      converts = prompt["actions"].select { |a| a["type"] == "convert" && corporation_type(a["entity"]) == :regional }
      return nil if converts.empty?

      @held_regional ||= converts.first["entity"]
      other = converts.find { |a| a["entity"] != @held_regional }
      other || prompt["actions"].find { |a| a["type"] == "pass" }
    end

    # The Consolidation round follows the first Level-5 train (§11.8), but a rush game ends when the bank breaks
    # (GAME_END_CHECK bank: :current_or). On the 18xx.games engine the 3-player game ended that way in Train
    # Phase 3, turn 13 (CI run 45449578025, S2 game 2; #596; the end reason itself was not read). While a
    # consolidation target is missing the director withholds every dividend: the money stays in the treasuries
    # instead of leaving the bank. Legal and on offer; everything else is the bot's play.
    def spare_bank(round, step, prompt, missing)
      return nil unless @rush && round == "operating" && step == "Dividend"
      return nil unless missing.any? { |k| k.start_with?("consolidation/") }

      prompt["actions"].find { |a| a["type"] == "dividend" && a["kind"] == "withhold" }
    end

    # A corporation is over its train limit only when the limit falls (Phase 4: major 4 to 3, minor and regional 2 to 1)
    # while it holds more trains than the new one (#224). The bot buys a train per turn only while it is affordable and
    # often stays below the limit. While the discard is missing, the director fills every corporation up to its limit
    # in Phases 2 and 3 with the cheapest depot train offered, so the purchase of the first 4 train by anybody leaves
    # the full ones crowded. Everything else is the bot's play.
    DISCARD_TARGET = "operating/DiscardTrain/discard_train"

    def crowd_trains(round, step, prompt, missing)
      return nil unless round == "operating" && step == "BuyTrain" && missing.include?(DISCARD_TARGET)
      return nil unless %w[2 3].include?(@mirror.phase.name)

      depot = prompt["actions"].select do |a|
        next false unless a["type"] == "buy_train"

        train = @mirror.train_by_id(a["train"])
        train && !train.owned_by_corporation? && (a["variant"].nil? || a["variant"] == train.variants.keys.first)
      end
      corporation = @mirror.corporation_by_id(depot.first&.fetch("entity"))
      return nil unless corporation && corporation.trains.size < @mirror.train_limit(corporation)

      depot.min_by { |a| a["price"] }
    end

    def reserve_question?(action)
      corporation = @mirror.corporation_by_id(action["shares"].first.sub(/_\d+\z/, ""))
      corporation.owner && corporation.owner.id != action["entity"] && @mirror.can_reserve_regional?(corporation.owner, corporation)
    end

    def bot_move(pid, prompt)
      @bot.reseed(@seed * 1_000_003 + @mirror.raw_actions.size)
      action = @bot.choose(player_id: pid)
      return nil unless action

      JSON.parse(JSON.generate(action.to_h.reject { |k, _| %w[id created_at user].include?(k) }))
    end

    # A request that outlives the client's read timeout (Clients::Net, 120 s) or loses its connection stops the run
    # as a problem, so the report (end reason, verdict) is still printed (#596: full run 45507429707 ended without it).
    REQUEST_ERRORS = [Net::ReadTimeout, Net::OpenTimeout, EOFError, SystemCallError].freeze

    def request(pid, verb, path, body, what)
      started = clock
      client_for(pid).call(verb, path, body)
    rescue *REQUEST_ERRORS => e
      @ledger.problem(:timeout, "#{verb.to_s.upcase} #{path} after #{(clock - started).round(1)} s at #{what}: #{e.class}: #{e.message}")
      :timeout
    end

    def offered_in?(action, prompt)
      return true if prompt["actions"].include?(action)
      return false unless %w[bid buy_company buy_corporation].include?(action["type"])

      prompt["ranges"].any? do |r|
        target = action["company"] || action["corporation"]
        (action["type"] == "bid" || r["type"] == action["type"]) &&
          r["entity"] == action["entity"] && r["company"] == target &&
          action["price"].between?(r["min"], r["max"]) && ((action["price"] - r["min"]) % r["step"]).zero?
      end
    end

    def post(pid, state, action, round, step)
      status, body, took = request(pid, :post, "/games/#{@game_id}/actions", { action: action, seq: state["seq"] },
                                   "#{round}/#{step} #{action.to_json[0, 200]}")
      return status if status.is_a?(Symbol)

      @ledger.post_seconds << took
      unless status == 200
        @ledger.problem(:rejected, "#{round}/#{step} #{action.to_json[0, 200]}: #{status} #{body.inspect[0, 200]}")
        return :rejected
      end

      @ledger.executed[key(round, step, action)] += 1
      Live.process(@mirror, action.merge("user" => pid))
      if @mirror.exception
        @ledger.problem(:mirror_diverged, "mirror rejected an action the server accepted: #{@mirror.exception.message}")
        return :mirror_diverged
      end
      @log&.call(state["seq"] + 1, round, step, action)
      body.merge("_fresh" => true)
    end

    def finish(status, count, state, started)
      view = state["state"]
      finished = view["meta"]["finished"]
      status = :finished if finished
      missing = @targets - @ledger.executed.keys
      @ledger.problem(:not_finished, "stopped with #{status} after #{count} actions") if @finish && !finished
      Result.new(slice: "#{@slice_name} / #{@game_name}", status: status, actions: count, seed: @seed, game_id: @game_id, ledger: @ledger,
                 missing: missing, finished: finished, standings: view["meta"]["standings"],
                 seconds: (clock - started).round(1), detail: nil, targets: @targets,
                 phase: "#{@mirror.phase.name} (turn #{@mirror.turn})",
                 end_reason: @mirror.game_end_reason, bank_cash: @mirror.bank.cash)
    end

    def abort_result(status, detail, started)
      @ledger.problem(status, detail)
      Result.new(slice: "#{@slice_name} / #{@game_name}", status: status, actions: 0, seed: @seed, game_id: nil, ledger: @ledger,
                 missing: @targets, finished: false, standings: nil, seconds: (clock - started).round(1), detail: detail,
                 targets: @targets)
    end
  end
end
