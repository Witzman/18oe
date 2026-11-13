# frozen_string_literal: true

require "engine"
require_relative "game_session"
require_relative "view"

module Oe
  # Time series for the views (#115), derived by replaying the action log and
  # served on request only (GET /games/:id/history), never in the default state
  # (#91). Nothing here is invented: player values and operating-round revenue
  # are the engine's own records (`player.history` / `PlayerInfo`,
  # `corporation.operating_history` / `OperatingInfo`); only the share price has
  # no engine record, so it is sampled after every action while replaying.
  #
  #   history = Oe::History.replay(names, id:, seed:, payloads:)
  #   history.to_h  # => { share_prices:, player_values:, revenue: }
  class History
    GAME_CLASS = -> { Engine::Game::G18OE::Game }

    attr_reader :game

    # names: as for the game (array or { id => name }); payloads: raw actions
    # of the log. Raises if the engine refuses an action (the log is the truth).
    def self.replay(names, id:, seed:, payloads:)
      game = GAME_CLASS.call.new(names, id: id, seed: seed)
      history = new(game)
      payloads.each do |payload|
        game.process_action(payload)
        raise "history replay of game #{id} broke: #{game.exception.message}" if game.exception

        history.record
      end
      history
    end

    CACHE_SIZE = 16
    @cache = {}
    @cache_mutex = Mutex.new

    # The history of a stored game at its current log position. A replay is as
    # costly as loading the game, so the last few results are kept per
    # (store, game, seq); the log stays the truth.
    def self.for_session(store, session)
      key = [store.object_id, session.id, session.seq]
      @cache_mutex.synchronize { return @cache[key] if @cache.key?(key) }
      result = replay(GameSession.player_names(session.seats), id: session.id, seed: session.seed,
                                                              payloads: store.action_payloads(session.id)).to_h
      @cache_mutex.synchronize do
        @cache[key] = result
        @cache.shift while @cache.size > CACHE_SIZE
      end
      result
    end

    def initialize(game)
      @game = game
      @prices = {}
      @last = {}
      record
    end

    # Call after every processed action: notes a price point when a
    # corporation's share price changed (or it was closed, price nil).
    def record
      @game.corporations.each do |corp|
        price = corp.closed? ? nil : corp.share_price&.price
        next if @last.key?(corp.id) ? @last[corp.id] == price : price.nil?

        @last[corp.id] = price
        (@prices[corp.id] ||= []) << {
          action: @game.current_action_id,
          turn: @game.turn,
          round: round_type(@game.round),
          number: @game.round.respond_to?(:round_num) ? @game.round.round_num : nil,
          price: price,
        }
      end
    end

    def to_h
      {
        share_prices: @prices.sort_by { |id, _| id.to_s }.to_h,
        player_values: player_values,
        revenue: revenue,
      }
    end

    private

    def round_type(round)
      Oe::View.round_type(round)
    end

    # One entry per recorded round end (and the game end), in engine order.
    def player_values
      @game.players.to_h do |p|
        [p.id, p.history.map { |i| { round: i.round_name, turn: i.turn, number: i.round_no, value: i.value } }]
      end
    end

    # Per corporation and operating round: what the run earned and how it was
    # paid (payout / half / withhold).
    def revenue
      @game.corporations.each_with_object({}) do |corp, h|
        rows = corp.operating_history.map do |(turn, number), info|
          { turn: turn, number: number, revenue: info.revenue, dividend: info.dividend_kind.to_s }
        end
        h[corp.id] = rows unless rows.empty?
      end
    end
  end
end
