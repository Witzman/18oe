# frozen_string_literal: true

require "engine"
require_relative "build_id"
require_relative "store"

module Oe
  # One game, rebuilt from its action log (#34). The loaded game is cached per
  # process keyed by `seq`; the cache is only an accelerator — the log is the
  # truth, and any doubt (failed action, failed commit, other process wrote)
  # drops the cache entry and replays from the log.
  class GameSession
    class Error < StandardError; end
    class NotFound < Error; end
    # Someone else appended first: the caller's `expected_seq` is stale.
    class Conflict < Error; end
    # The engine refused the action (or it is not appendable). Nothing written.
    class Rejected < Error; end
    # The caller's authorize block said no (not seated / not your turn). Nothing written.
    class Forbidden < Error
      attr_reader :code

      def initialize(code, message)
        super(message)
        @code = code
      end
    end

    UPSTREAM_COMMIT = "06b3f0b37" # lib/engine/UPSTREAM.md
    GAME_CLASS = -> { Engine::Game::G18OE::Game }
    # Undo/redo would rewrite history; the log stays append-only for now.
    FORBIDDEN = %w[undo redo].freeze

    attr_reader :id, :game, :seq

    def self.engine_rev
      "#{UPSTREAM_COMMIT}+#{Oe::BuildId.value}"
    end

    # seats: [{"seat" => 0, "kind" => "human", "account_id" => "anna", "name" => "Anna"}, ...]
    def self.create(store, seats:, seed:, status: "active")
      id = store.create_game(seats: seats, seed: seed, engine_rev: engine_rev, status: status)
      load(store, id)
    end

    def self.player_names(seats)
      seats.to_h { |s| [player_id(s), s["name"] || player_id(s)] }
    end

    # Engine player id of a seat.
    def self.player_id(seat)
      "p#{seat['seat']}"
    end

    def self.load(store, id)
      row = store.game(id) or raise NotFound, "game #{id}"
      cached = store.sessions[id]
      seq = store.last_seq(id)
      game = cached[:game] if cached && cached[:seq] == seq
      unless game
        game = replay(store, row, id)
        store.sessions[id] = { seq: seq, game: game }
      end
      new(store, row, game, seq)
    end

    def self.replay(store, row, id)
      payloads = store.action_payloads(id)
      game = GAME_CLASS.call.new(player_names(row["seats"]), id: id, seed: row["seed"], actions: payloads)
      raise Error, "replay of game #{id} broke: #{game.exception.message}" if game.exception

      game
    end

    def initialize(store, row, game, seq)
      @store = store
      @row = row
      @id = row["id"]
      @game = game
      @seq = seq
    end

    def seats
      @row["seats"]
    end

    def seed
      @row["seed"]
    end

    def status
      @store.game(@id)["status"]
    end

    # action: an Engine::Action built against `game`, or a Hash (as from the API).
    # expected_seq: the seq the caller based its decision on (nil = "latest").
    # Returns the new seq. Raises Conflict / Rejected; on any error the log is
    # unchanged.
    #
    # A block, if given, is called with the up-to-date game inside the
    # transaction, before the action is applied; it authorizes by raising
    # Forbidden (so it never races with another thread mutating the game).
    def append(action, actor:, expected_seq: nil)
      # Always go through the hash form: it is what the API sends and what the
      # replay reads, and it rebuilds the action against the *current* game.
      action = action.to_h if action.respond_to?(:to_h) && !action.is_a?(Hash)
      type = action["type"]
      raise Rejected, "#{type} cannot be appended" if FORBIDDEN.include?(type.to_s)

      @store.transaction do
        db_seq = @store.last_seq(@id)
        raise Conflict, "expected seq #{expected_seq}, log is at #{db_seq}" if expected_seq && expected_seq != db_seq

        # Our game object must match the log; otherwise the action may refer to
        # a stale state (objects of an old game instance) — reload.
        refresh!(db_seq)
        raise Rejected, "game #{@id} is finished" if @game.finished

        yield @game if block_given?

        apply(action, db_seq)
        payload = @game.raw_actions.last
        @store.insert_action(game_id: @id, seq: db_seq + 1, actor: actor.to_s, payload: payload)
        @store.set_status(@id, "finished") if @game.finished
        @seq = db_seq + 1
        @store.sessions[@id] = { seq: @seq, game: @game }
        @seq
      end
    rescue Conflict, Forbidden
      raise # raised before the game was touched: the cache is still good
    rescue StandardError
      @store.sessions.delete(@id) # game object may be half-mutated or ahead of the log
      raise
    end

    private

    def refresh!(db_seq)
      return if db_seq == @seq && @store.sessions[@id]&.fetch(:game).equal?(@game)

      @game = self.class.replay(@store, @row, @id)
      @seq = db_seq
    end

    def apply(action, db_seq)
      @game.process_action(action)
      return unless @game.exception

      raise Rejected, "#{@game.exception.class}: #{@game.exception.message} (at seq #{db_seq})"
    end
  end
end
