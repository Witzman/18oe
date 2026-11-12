# frozen_string_literal: true

require "fileutils"
require "json"
require "monitor"
require "sqlite3"
require "time"

module Oe
  # SQLite persistence (#34/#6): two tables, `games` and `actions`. State is
  # never stored — only the action log; Oe::GameSession replays it.
  #
  # One connection per Store, guarded by a mutex (Puma is multi-threaded);
  # transactions are BEGIN IMMEDIATE so a second process also queues behind
  # the writer (busy_timeout) instead of failing half way.
  class Store
    SCHEMA_VERSION = 2
    DEFAULT_PATH = "/data/18oe.sqlite3"

    MIGRATIONS = {
      1 => <<~SQL,
        CREATE TABLE games (
          id         INTEGER PRIMARY KEY,
          created_at TEXT NOT NULL,
          status     TEXT NOT NULL,        -- 'lobby' | 'active' | 'finished'
          seats      TEXT NOT NULL,        -- JSON: [{seat:, kind:, account_id:, name:}]
          seed       INTEGER NOT NULL,     -- fixed: the engine shuffles with it
          engine_rev TEXT NOT NULL         -- upstream commit + own build id
        );
        CREATE TABLE actions (
          id          INTEGER PRIMARY KEY,
          game_id     INTEGER NOT NULL REFERENCES games(id),
          seq         INTEGER NOT NULL,    -- gapless, 1.. per game = engine action id
          actor       TEXT NOT NULL,       -- account_id or 'bot:<seat>'
          action_type TEXT NOT NULL,
          payload     TEXT NOT NULL,       -- JSON, exactly the engine's action.to_h
          created_at  TEXT NOT NULL,
          UNIQUE (game_id, seq)
        );
      SQL
      2 => <<~SQL
        CREATE TABLE incidents (
          id         INTEGER PRIMARY KEY,
          game_id    INTEGER NOT NULL REFERENCES games(id),
          seq        INTEGER NOT NULL,     -- log position when it happened
          kind       TEXT NOT NULL,        -- bot_error | bot_rejected | fallback | stuck
          message    TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
      SQL
    }.freeze

    attr_reader :path, :sessions

    def initialize(path = ENV["DATABASE_PATH"] || DEFAULT_PATH)
      @path = path
      @mutex = Monitor.new
      @sessions = {} # GameSession cache: game_id => { seq:, game: }; speed only
      FileUtils.mkdir_p(File.dirname(path)) unless path == ":memory:"
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = true
      @db.busy_timeout = 5000
      @db.execute("PRAGMA journal_mode = WAL") unless path == ":memory:"
      @db.execute("PRAGMA foreign_keys = ON")
      migrate!
    end

    def close
      @mutex.synchronize { @db.close }
    end

    def schema_version
      @mutex.synchronize { @db.get_first_value("PRAGMA user_version") }
    end

    # Runs the block inside BEGIN IMMEDIATE ... COMMIT; any exception rolls back.
    def transaction
      @mutex.synchronize do
        @db.execute("BEGIN IMMEDIATE")
        begin
          result = yield
          @db.execute("COMMIT")
          result
        rescue Exception # rubocop:disable Lint/RescueException
          @db.execute("ROLLBACK") if @db.transaction_active?
          raise
        end
      end
    end

    def create_game(seats:, seed:, engine_rev:, status: "active")
      transaction do
        @db.execute(
          "INSERT INTO games (created_at, status, seats, seed, engine_rev) VALUES (?, ?, ?, ?, ?)",
          [now, status, JSON.generate(seats), seed, engine_rev],
        )
        @db.last_insert_row_id
      end
    end

    def game(id)
      row = @mutex.synchronize { @db.get_first_row("SELECT * FROM games WHERE id = ?", [id]) }
      row && row.merge("seats" => JSON.parse(row["seats"]))
    end

    # All games, oldest first (PoC: a handful, so no paging).
    def games
      rows = @mutex.synchronize { @db.execute("SELECT * FROM games ORDER BY id") }
      rows.map { |row| row.merge("seats" => JSON.parse(row["seats"])) }
    end

    def active_game_count
      @mutex.synchronize { @db.get_first_value("SELECT COUNT(*) FROM games WHERE status = 'active'") }
    end

    # The log with metadata (debugging / transparency), ascending seq.
    def action_rows(game_id)
      rows = @mutex.synchronize do
        @db.execute("SELECT seq, actor, action_type, payload, created_at FROM actions WHERE game_id = ? ORDER BY seq", [game_id])
      end
      rows.map { |r| r.merge("payload" => JSON.parse(r["payload"])) }
    end

    # Things that went wrong around a game without stopping it (bot failures).
    def add_incident(game_id:, seq:, kind:, message:)
      @mutex.synchronize do
        @db.execute("INSERT INTO incidents (game_id, seq, kind, message, created_at) VALUES (?, ?, ?, ?, ?)",
                    [game_id, seq, kind, message.to_s[0, 500], now])
      end
    end

    def incidents(game_id)
      @mutex.synchronize { @db.execute("SELECT seq, kind, message, created_at FROM incidents WHERE game_id = ? ORDER BY id", [game_id]) }
    end

    def set_status(id, status)
      @mutex.synchronize { @db.execute("UPDATE games SET status = ? WHERE id = ?", [status, id]) }
    end

    def last_seq(game_id)
      @mutex.synchronize do
        @db.get_first_value("SELECT COALESCE(MAX(seq), 0) FROM actions WHERE game_id = ?", [game_id])
      end
    end

    # Call inside #transaction: the caller has checked `seq` against last_seq.
    def insert_action(game_id:, seq:, actor:, payload:)
      @mutex.synchronize do
        @db.execute(
          "INSERT INTO actions (game_id, seq, actor, action_type, payload, created_at) VALUES (?, ?, ?, ?, ?, ?)",
          [game_id, seq, actor, payload["type"].to_s, JSON.generate(payload), now],
        )
      end
    end

    # Payload hashes in ascending seq, as the engine's replay expects them.
    def action_payloads(game_id)
      rows = @mutex.synchronize do
        @db.execute("SELECT payload FROM actions WHERE game_id = ? ORDER BY seq", [game_id])
      end
      rows.map { |row| JSON.parse(row["payload"]) }
    end

    private

    def migrate!
      @mutex.synchronize do
        current = @db.get_first_value("PRAGMA user_version")
        (current + 1..SCHEMA_VERSION).each do |version|
          @db.transaction do
            @db.execute_batch(MIGRATIONS.fetch(version))
            @db.execute("PRAGMA user_version = #{version}")
          end
        end
      end
    end

    def now
      Time.now.utc.iso8601(3)
    end
  end
end
