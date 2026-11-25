# frozen_string_literal: true

require "oe/bot_runner"
require "oe/store"

# The test game of the long view specs (view_spec, view_order_spec; #602 part b, Option C, owner 2026-11-25).
#
# They played the strategy game seed 1 / 4 players before. That game no longer reaches its end in the full stage:
# from about action 4000 one RunRoutes offer costs 40-150 s (two AutoRouter searches, mostly the trial of the
# Orient Express duty), and the offer at action 4972 hangs for more than 26 min. The engine and its log stay as they
# are (no patch); the specs move to a game that does end: the bots-only game of bot_runner_spec :full_game
# (3 bots, seed 1, Oe::BotRunner over an in-memory store), green to its regular end in the full stage. It is played
# by the same runner as there (same seats, seed, bot, reseeding and fallback). The block's views use their own
# random stream (Oe::View: Random.new(0)), not the bot's.
#
#   game, incidents = OeCheckGame.play(max: n) { |game| ... }
#
# The block is called with the game before every bot move, i.e. on the state the bot decides on (every state of
# the game but the last; the caller looks at the returned game for that one). The game ends, stops (no bot has a
# move) or `max` moves are played. Returns the game and the runner's incidents (bot errors and fallbacks).
module OeCheckGame
  PLAYERS = 3
  SEED = 1

  # Oe::BotRunner's bot interface (#reseed, #choose, #legal_actions) around an Oe::Bot, calling `before` first.
  Watch = Struct.new(:bot, :game, :before) do
    def reseed(seed) = bot.reseed(seed)
    def legal_actions(player_id) = bot.legal_actions(player_id)

    def choose(player_id: nil)
      before&.call(game)
      bot.choose(player_id: player_id)
    end
  end

  def self.play(max:, &before)
    store = Oe::Store.new(":memory:")
    factory = ->(game, rng) { Watch.new(Oe::Bot.new(game, rng: rng), game, before) }
    runner = Oe::BotRunner.new(store, bot_factory: factory)
    seats = Array.new(PLAYERS) { |i| { "seat" => i, "kind" => "bot", "name" => "S#{i}" } }
    id = Oe::GameSession.create(store, seats: seats, seed: SEED).id
    runner.drain(id, max: max)
    [Oe::GameSession.load(store, id).game, store.incidents(id)]
  end
end
