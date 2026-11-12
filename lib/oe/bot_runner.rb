# frozen_string_literal: true

require "thread"
require_relative "bot"
require_relative "game_session"

module Oe
  # Lets bots play on the server (#39): whenever a bot seat is on turn, the
  # runner picks a move with Oe::Bot and appends it to the log
  # (actor "bot:<seat>", its own seq per move) until a human is on turn or
  # the game ends.
  #
  #   runner.kick(game_id)   # async: a background thread drains the chain
  #   runner.drain(game_id)  # the same, synchronously (tests, resume)
  #
  # Per game there is at most one worker (`kick` while one runs only marks it
  # dirty, so it looks again before it exits). Appends carry `expected_seq`,
  # so even two workers could never produce a duplicate move.
  #
  # Robustness: a game must never hang on a bot. If the bot raises or its action
  # is rejected, a random legal action of that seat is played instead and an
  # incident is stored (table `incidents`). If even that fails the chain stops
  # with a `stuck` incident (the next kick tries again).
  class BotRunner
    MAX_MOVES = 100_000
    FALLBACK_TRIES = 6
    SEED_STRIDE = 1_000_003

    attr_reader :store

    # bot_factory: (game, rng) -> object responding to #reseed, #choose(player_id:), #legal_actions(pid)
    def initialize(store, bot_factory: nil)
      @store = store
      @bot_factory = bot_factory || ->(game, rng) { Oe::Bot.new(game, rng: rng) }
      @mutex = Mutex.new
      @running = {}
      @dirty = {}
      @bots = {} # game_id => [game object, bot]; the bot belongs to one game instance
    end

    # Asynchronous: returns immediately.
    def kick(game_id)
      @mutex.synchronize do
        if @running[game_id]
          @dirty[game_id] = true
          return false
        end
        @running[game_id] = true
      end
      Thread.new { work(game_id) }
      true
    end

    # Waits until no worker runs for the game (tests). Returns true if idle in time.
    def wait_idle(game_id, timeout: 120)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      while @mutex.synchronize { @running[game_id] }
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.01
      end
      true
    end

    # After a process start: pick up games whose chain was cut by a restart.
    def resume_all
      @store.games.each do |row|
        next unless row["status"] == "active" && row["seats"].any? { |s| s["kind"] == "bot" }

        kick(row["id"])
      end
    end

    # Plays bot moves until a human is on turn / the game ends / `max` moves.
    # Returns the number of moves played.
    def drain(game_id, max: MAX_MOVES)
      played = 0
      while played < max
        session = GameSession.load(@store, game_id)
        break if session.game.finished

        seat = acting_bot_seat(session) or break
        step = play_one(session, seat)
        break if step == :stuck

        played += 1 if step == :played
      end
      played
    rescue GameSession::NotFound
      played
    end

    private

    def work(game_id)
      loop do
        @mutex.synchronize { @dirty[game_id] = false }
        begin
          drain(game_id)
        rescue StandardError => e
          incident(game_id, seq_of(game_id), "stuck", "runner crashed: #{e.class}: #{e.message}")
        end
        done = @mutex.synchronize do
          if @dirty[game_id]
            false
          else
            @running.delete(game_id)
            @dirty.delete(game_id)
            true
          end
        end
        break if done
      end
    end

    # First active seat that is a bot and has something to play.
    def acting_bot_seat(session)
      seats = session.seats.to_h { |s| [GameSession.player_id(s), s] }
      session.game.active_players.each do |player|
        seat = seats[player.id]
        return seat if seat && seat["kind"] == "bot" && !bot_for(session).legal_actions(player.id).empty?
      end
      nil
    end

    def bot_for(session)
      cached = @bots[session.id]
      return cached.last if cached && cached.first.equal?(session.game)

      bot = @bot_factory.call(session.game, Random.new(0))
      @bots[session.id] = [session.game, bot]
      bot
    end

    # :played | :retry (conflict, someone else moved) | :stuck
    def play_one(session, seat)
      pid = GameSession.player_id(seat)
      actor = "bot:#{seat['seat']}"
      bot = bot_for(session)
      bot.reseed(session.seed * SEED_STRIDE + session.seq)

      begin
        action = bot.choose(player_id: pid)
        raise "bot returned no action" unless action

        session.append(action, actor: actor, expected_seq: session.seq)
        :played
      rescue GameSession::Conflict
        :retry
      rescue StandardError => e
        kind = e.is_a?(GameSession::Rejected) ? "bot_rejected" : "bot_error"
        incident(session.id, session.seq, kind, "#{e.class}: #{e.message}")
        fallback(session, seat, pid, actor)
      end
    end

    # A random legal action of the seat; reload the game before each try, because a
    # rejected action leaves the cached game half changed (GameSession drops it).
    def fallback(session, _seat, pid, actor)
      game_id = session.id
      FALLBACK_TRIES.times do |i|
        fresh = GameSession.load(@store, game_id)
        legal = bot_for(fresh).legal_actions(pid)
        return :retry if legal.empty? # nothing left to do for this seat

        pick = legal.sample(random: Random.new(fresh.seed * SEED_STRIDE + fresh.seq + i))
        begin
          fresh.append(pick, actor: actor, expected_seq: fresh.seq)
          incident(game_id, fresh.seq, "fallback", "random legal action #{pick.class.name.split('::').last} played")
          return :played
        rescue GameSession::Conflict
          return :retry
        rescue StandardError => e
          incident(game_id, fresh.seq, "bot_rejected", "fallback try #{i + 1}: #{e.class}: #{e.message}")
        end
      end
      incident(game_id, seq_of(game_id), "stuck", "no accepted action for #{pid} after #{FALLBACK_TRIES} tries")
      :stuck
    end

    def incident(game_id, seq, kind, message)
      @store.add_incident(game_id: game_id, seq: seq, kind: kind, message: message)
    rescue StandardError
      nil # never let bookkeeping stop a game
    end

    def seq_of(game_id)
      @store.last_seq(game_id)
    end
  end
end
