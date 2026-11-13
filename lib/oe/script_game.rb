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
  # Keys: "round/Step/type", for `choose` "round/Step/choose:<choice>".
  class ScriptGame
    SLICE_DIR = File.join(__dir__, "script_game", "slices")

    Problem = Struct.new(:kind, :detail, keyword_init: true)

    # What the run saw. `executed` counts accepted actions by key, `offered`
    # what prompts listed (so "offered but never executed" is visible).
    class Ledger
      attr_reader :executed, :offered, :problems, :get_seconds, :post_seconds, :action_counts, :range_counts, :bytes

      def initialize
        @executed = Hash.new(0)
        @offered = Hash.new(0)
        @problems = []
        @get_seconds = []
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
                        :seconds, :detail, :targets, keyword_init: true) do
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
               when "choose" then action["choice"]
               when "par" then corporation_type(action["corporation"])
               when "buy_shares", "sell_shares" then corporation_type(action["shares"].first.sub(/_\d+\z/, ""))
               end
      "#{round}/#{step}/#{[type, detail].compact.join(':')}"
    end

    def corporation_type(id)
      @mirror.corporation_by_id(id)&.type
    end

    attr_reader :game_name

    def self.games(slice)
      slice(slice).fetch("games").size
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
        result = step_once(pid, state)
        if result.is_a?(Symbol)
          status = result
          break
        end
        state = result
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

      status, body, took = client_for(pid).call(:get, "/games/#{@game_id}")
      @ledger.get_seconds << took
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
    # normal game never reaches on its own (see #rush?); the director then
    # steers towards it first.
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

      range = prompt["ranges"].find { |r| missing.include?(key(round, step, r)) }
      range && { "type" => "bid", "entity" => range["entity"], "entity_type" => "player",
                 "company" => range["company"], "price" => range["min"] }
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

    def offered_in?(action, prompt)
      return true if prompt["actions"].include?(action)
      return false unless action["type"] == "bid"

      prompt["ranges"].any? do |r|
        r["entity"] == action["entity"] && r["company"] == action["company"] &&
          action["price"].between?(r["min"], r["max"]) && ((action["price"] - r["min"]) % r["step"]).zero?
      end
    end

    def post(pid, state, action, round, step)
      status, body, took = client_for(pid).call(:post, "/games/#{@game_id}/actions", { action: action, seq: state["seq"] })
      @ledger.post_seconds << took
      unless status == 200
        @ledger.problem(:rejected, "#{round}/#{step} #{action.to_json[0, 200]}: #{status} #{body.inspect[0, 200]}")
        return :rejected
      end

      @ledger.executed[key(round, step, action)] += 1
      @mirror.process_action(action.merge("user" => pid))
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
                 seconds: (clock - started).round(1), detail: nil, targets: @targets)
    end

    def abort_result(status, detail, started)
      @ledger.problem(status, detail)
      Result.new(slice: "#{@slice_name} / #{@game_name}", status: status, actions: 0, seed: @seed, game_id: nil, ledger: @ledger,
                 missing: @targets, finished: false, standings: nil, seconds: (clock - started).round(1), detail: detail,
                 targets: @targets)
    end
  end
end
