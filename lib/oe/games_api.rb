# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "accounts"
require_relative "bot_runner"
require_relative "catalog"
require_relative "history"
require_relative "game_session"
require_relative "store"
require_relative "view"

module Oe
  # The game endpoints (#36). Sinatra extension: `register Oe::GamesApi`.
  # Expects the host app to provide `settings.store` and the helpers
  # `json(status, payload)`, `current_account`, `api_error(status, code, message)`.
  #
  # Errors are always JSON `{error: <code>, message: <text>}`:
  #   400 bad_request   401 login_required   403 forbidden / not_your_turn
  #   404 not_found     409 conflict (stale seq)   422 rejected / invalid_seats / unknown_player / game_limit
  module GamesApi
    MAX_ACTIVE_DEFAULT = 10
    RUNNER_LOCK = Mutex.new

    # One BotRunner per store (tests swap the store).
    def self.runner_for(store)
      RUNNER_LOCK.synchronize do
        @runners ||= {}.compare_by_identity
        @runners[store] ||= BotRunner.new(store)
      end
    end

    module Helpers
      def store
        settings.store
      end

      # Let bots play after a game was created or a human moved. Mode (settings.bot_mode):
      # :async = background thread (production), :inline = synchronous (tests), :off.
      def kick_bots(game_id)
        runner = GamesApi.runner_for(store)
        case settings.bot_mode
        when :async then runner.kick(game_id)
        when :inline then runner.drain(game_id)
        end
      end

      def player_range
        Engine::Game::G18OE::Game::PLAYER_RANGE
      end

      # "p<n>" for the seat the logged-in account holds in this game, else nil.
      def viewer_player_id(seats)
        seat = seats.find { |s| s["account_id"] == current_account["id"] }
        seat && GameSession.player_id(seat)
      end

      def load_session(id)
        GameSession.load(store, Integer(id))
      rescue ArgumentError, GameSession::NotFound
        halt api_error(404, "not_found", "no such game")
      end

      def envelope(session)
        viewer = viewer_player_id(session.seats)
        {
          id: session.id,
          status: session.status,
          seats: session.seats,
          viewer: viewer,
          seq: session.seq,
          state: Oe::View.render(session.game, viewer: viewer, seq: session.seq,
                                               log: (params["log"] || 40).to_i),
        }
      end

      # What the list and /version say about whose turn it is (#152): from the
      # stored turn summary, no replay. Never names accounts, only whether the
      # logged-in viewer's own seat is among the acting ones.
      def turn_info(row)
        turn = GameSession.turn_for(store, row)
        mine = viewer_player_id(row["seats"])
        { round: turn["round"], acting: turn["acting"],
          viewer_to_act: !mine.nil? && row["status"] != "finished" && turn["acting"].include?(mine) }
      end

      def json_body
        data = JSON.parse(request.body.read)
        data.is_a?(Hash) ? data : halt(api_error(400, "bad_request", "JSON object expected"))
      rescue JSON::ParserError
        halt api_error(400, "bad_request", "invalid JSON")
      end

      # A human seat names its player either by `account` (name or e-mail,
      # case-insensitive; #212) or by `account_id` (the opaque id, kept for
      # scripted games). Unknown name/e-mail: one neutral 422 that does not say
      # whether an e-mail is registered; failed lookups (and every e-mail
      # lookup) count against a per-creator limit, so this is no oracle.
      def human_account(entry, index)
        if entry.key?("account")
          limit = settings.lookup_limit
          halt api_error(429, "rate_limited", "too many attempts, try again later") if limit.blocked?(current_account["id"])
          account = Accounts.resolve(store, entry["account"])
          limit.fail!(current_account["id"]) if account.nil? || entry["account"].to_s.include?("@")
          halt api_error(422, "unknown_player", "no registered player found for seat #{index + 1}") unless account
        else
          account = Accounts.find(store, entry["account_id"])
          halt api_error(422, "invalid_seats", "unknown account at seat #{index}") unless account
        end
        account
      end

      def build_seats(data)
        raw = data["seats"]
        return halt(api_error(422, "invalid_seats", "seats must be a list")) unless raw.is_a?(Array)

        min, max = player_range
        unless (min..max).cover?(raw.size)
          return halt(api_error(422, "invalid_seats", "#{min} to #{max} seats required, got #{raw.size}"))
        end

        humans = []
        seats = raw.each_with_index.map do |entry, i|
          kind = entry.is_a?(Hash) ? entry["kind"] : nil
          case kind
          when "human"
            account = human_account(entry, i)
            humans << account["id"]
            { "seat" => i, "kind" => "human", "account_id" => account["id"], "name" => account["name"] }
          when "bot"
            { "seat" => i, "kind" => "bot", "name" => "Bot #{i + 1}" }
          else
            halt api_error(422, "invalid_seats", "seat #{i}: kind must be human or bot")
          end
        end
        halt api_error(422, "invalid_seats", "an account may hold only one seat") if humans.uniq.size != humans.size
        halt api_error(422, "invalid_seats", "you must hold a seat yourself") unless humans.include?(current_account["id"])
        seats
      end

      # Entities that are not active themselves but act on behalf of the
      # acting side (see Oe::LegalActions#acting_for, #132): a regional that its
      # president converts, the president selling shares in a train purchase.
      # Allowed when the entity belongs to the viewer and the viewer is the
      # acting player (or the president of the active corporation).
      def acting_for?(game, viewer, entity_id)
        other = game.players.find { |p| p.id == entity_id } || game.corporation_by_id(entity_id)
        return false unless other

        other_player = other.player? ? other : other.player
        return false unless other_player && other_player.id == viewer

        game.round.active_entities.any? do |e|
          (e.player? ? e : e.player)&.id == viewer
        end
      end

      # Authorization as a block for GameSession#append: runs inside the
      # transaction on the current state. The viewer must hold a seat and be
      # the acting player of the entity named in the action.
      def authorizer(viewer, action)
        lambda do |game|
          raise GameSession::Forbidden.new("forbidden", "you hold no seat in this game") unless viewer

          entity = game.round.active_entities.find { |e| e.id == action["entity"] }
          owner = entity && (entity.player? ? entity : entity.player)
          next if owner && owner.id == viewer
          next if acting_for?(game, viewer, action["entity"])

          raise GameSession::Forbidden.new("not_your_turn", "it is not your turn, or the entity is not yours to act for")
        end
      end
    end

    def self.registered(app)
      app.helpers Helpers

      # The static card catalog (#124): never changes within a build, so the
      # engine revision is its ETag and the browser revalidates cheaply.
      app.before "/catalog" do
        halt api_error(401, "login_required", "login required") unless current_account
      end

      app.get "/catalog" do
        etag "catalog-#{Oe::Catalog::SCHEMA}-#{GameSession.engine_rev}"
        cache_control :private, :no_cache
        content_type :json
        Oe::Catalog.json
      end

      app.get "/games" do
        mine = store.games.select { |g| g["seats"].any? { |s| s["account_id"] == current_account["id"] } }
        json 200, games: mine.map { |g|
          { id: g["id"], status: g["status"], seats: g["seats"], seq: store.last_seq(g["id"]), created_at: g["created_at"] }
            .merge(turn_info(g))
        }
      end

      app.post "/games" do
        data = json_body
        seats = build_seats(data)
        limit = (ENV["OE_MAX_GAMES"] || MAX_ACTIVE_DEFAULT).to_i
        if store.active_game_count >= limit
          halt api_error(422, "game_limit", "at most #{limit} active games")
        end

        seed = data["seed"].is_a?(Integer) ? data["seed"] : SecureRandom.random_number(2**31)
        session = GameSession.create(store, seats: seats, seed: seed)
        kick_bots(session.id)
        json 201, envelope(GameSession.load(store, session.id))
      end

      app.get "/games/:id" do
        json 200, envelope(load_session(params[:id]))
      end

      # Cheap: no replay, just the log position (polling, #8).
      app.get "/games/:id/version" do
        id = Integer(params[:id], exception: false)
        row = id && store.game(id)
        halt api_error(404, "not_found", "no such game") unless row

        json 200, { seq: store.last_seq(id), status: row["status"] }.merge(turn_info(row))
      end

      # Log lines after action id `from` (default 0 = all), at most `limit`
      # (default 100, max 500), oldest first (#152). `next` is the id to pass as
      # `from` for the following page, nil when there is nothing more.
      app.get "/games/:id/log" do
        session = load_session(params[:id])
        from = Integer(params["from"] || 0, exception: false)
        limit = Integer(params["limit"] || 100, exception: false)
        halt api_error(400, "bad_request", "from must be an integer >= 0") unless from && from >= 0
        halt api_error(400, "bad_request", "limit must be an integer 1..500") unless limit && (1..500).cover?(limit)

        lines = session.game.log.select { |e| e.action_id > from }
        page = lines.first(limit)
        json 200, lines: page.map { |e| { action: e.action_id, text: e.message.to_s } },
                  next: lines.size > limit ? page.last.action_id : nil, seq: session.seq
      end

      # Time series (#115): share price per corporation, player value and
      # operating-round revenue. Derived by replay, on request only (#91).
      app.get "/games/:id/history" do
        session = load_session(params[:id])
        json 200, { seq: session.seq }.merge(History.for_session(store, session))
      end

      app.get "/games/:id/actions" do
        session = load_session(params[:id])
        json 200, actions: store.action_rows(session.id), incidents: store.incidents(session.id)
      end

      app.post "/games/:id/actions" do
        data = json_body
        action = data["action"]
        seq = data["seq"]
        halt api_error(400, "bad_request", "action (object) and seq (integer) required") unless action.is_a?(Hash) && seq.is_a?(Integer)

        session = load_session(params[:id])
        viewer = viewer_player_id(session.seats)
        check = authorizer(viewer, action)

        begin
          session.append(action.merge("user" => viewer), actor: current_account["id"], expected_seq: seq, &check)
        rescue GameSession::Forbidden => e
          halt api_error(403, e.code, e.message)
        rescue GameSession::Conflict => e
          halt api_error(409, "conflict", e.message)
        rescue GameSession::Rejected => e
          halt api_error(422, "rejected", e.message)
        end
        kick_bots(session.id)
        json 200, envelope(GameSession.load(store, session.id))
      end
    end
  end
end
