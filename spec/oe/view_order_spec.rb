# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require_relative "../support/check_game"
require "json"

# #122: operating order and player priority in the view, checked against the
# sequence of `current` corporations of each operating round. The game examples play the bots-only test game of
# spec/support/check_game.rb (#602: 3 bots, seed 1; the strategy game seed 1 / 4 players before it no longer reaches
# its end), capped at GAME_CAP moves, to its end in the full stage (OE_FULL_GAME=1).
RSpec.describe "Oe::View order (#122)", :game_flow do
  def json(view) = JSON.parse(JSON.generate(view))

  it "lists the players in priority order with the priority deal first, and no operating order before the majors" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    meta = Oe::View.render(game, actions: false)[:meta]
    expect(meta[:priority]).to eq(%w[p0 p1 p2 p3])
    expect(meta[:operating_order]).to eq([])
    expect(json(meta)["priority"]).to eq(%w[p0 p1 p2 p3])
  end

  # The test game is played once for both game examples (#602: one whole game per file, not two). Each looked-at
  # state keeps what the checks need: the view's meta and the engine's side of it.
  before(:all) do
    @states = []       # operating-sequence check: one hash per rendered state
    @stock_states = [] # stock-round priority check: [view priority, priority deal player id]
    count = 0
    last_round = nil
    last_stock = nil
    @game, = OeCheckGame.play(max: GAME_CAP) do |game|
      round = game.round
      # #335: View.render per action dominates the run time. Operating rounds are checked on every action
      # (the sequence of `current` corporations needs each one); the other rounds on every 20th action and
      # whenever the round object changes (the invariants hold on any state).
      if !round.equal?(last_round) || Oe::View.round_type(round) == "operating" || (count % 20).zero?
        last_round = round
        step = round.active_step
        operator = round.respond_to?(:current_operator) ? round.current_operator : nil
        @states << {
          meta: Oe::View.render(game, actions: false, log: nil)[:meta],
          players: game.players.map(&:id),
          engine_order: game.operating_order.map(&:id),
          # Minor C's choice (Chris' step)
          pending: step.is_a?(Engine::Game::G18OE::Step::ChooseOperatingPosition),
          discard_operator: step.is_a?(Engine::Step::DiscardTrain) && operator ? operator.id : nil,
        }
      end
      # #335: render on the first action of each stock round object and every 10th action (cost)
      if round.is_a?(Engine::Round::Stock) && (!round.equal?(last_stock) || (count % 10).zero?)
        last_stock = round
        @stock_states << [Oe::View.render(game, actions: false, log: nil)[:meta][:priority], game.send(:priority_deal_player).id]
      end
      count += 1
    end
    @count = count
  end

  it "matches the actual operating sequence of every operating round and the next stock round's order (test game)" do
    rounds = 0
    announced = nil
    announced_ids = []
    announced_pending = false
    seen = []
    last_priority = nil
    out_of_turn = 0
    @states.each do |state|
      meta = state[:meta]
      order = meta[:operating_order]
      expect(meta[:priority].sort).to eq(state[:players].sort)
      expect(order.map { |o| o[:id] }).to eq(state[:engine_order]) unless meta[:round][:type] == "operating"
      if meta[:round][:type] == "operating"
        key = [meta[:round][:turn], meta[:round][:number]]
        # Minor C (#70): while the president of Golden Bell has not chosen its place, the order is still the
        # normal one; it is re-announced once, after the choice (the choice holds for this round only).
        pending = state[:pending]
        if key == announced && announced_pending && !pending
          announced_ids = order.map { |o| o[:id] }
          announced_pending = false
        end
        if key != announced
          unless announced.nil?
            expect(seen.uniq).to eq(announced_ids.select { |id| seen.include?(id) }), "round #{announced}"
            rounds += 1
          end
          announced = key
          announced_ids = order.map { |o| o[:id] }
          announced_pending = pending
          seen = []
        end
        expect(order.map { |o| o[:id] }).to eq(announced_ids) unless pending
        cur = meta[:current]
        if cur && cur[:kind] == "corporation"
          i = order.index { |o| o[:id] == cur[:id] }
          expect(i).not_to be_nil
          operator = state[:discard_operator]
          if operator && cur[:id] != operator
            # A train purchase that lowers the train limit (phase change) makes another corporation
            # discard out of turn (Engine::Step::DiscardTrain): it is current, but the operating one
            # still sets `done`. Seen in the full game since #72 changed its course (full workflow).
            o = order.index { |e| e[:id] == operator }
            expect(order.map { |e| e[:done] }).to eq(order.each_index.map { |j| j < o })
            out_of_turn += 1
          elsif pending
            # Minor C's choice (Chris' Step::ChooseOperatingPosition) names Golden Bell as current while the
            # first operator of the order has not run yet: nothing is done
            expect(order.map { |e| e[:done] }).to all(be(false))
          else
            expect(order.map { |o| o[:done] }).to eq(order.each_index.map { |j| j < i })
            seen << cur[:id]
          end
        end
      end
      last_priority = meta[:priority]
    end
    expect(rounds).to be >= 2
    expect(@game.finished).to be(true) if FULL_GAME
    warn "view_order: #{@count} actions, #{rounds} operating rounds, #{out_of_turn} out-of-turn discard checks" if ENV["OE_FULL_GAME"]
    expect(last_priority).not_to be_nil
  end

  it "puts the player after the last to act first during a stock round" do
    @stock_states.each do |prio, deal|
      expect(prio.first).to eq(deal)
      expect(prio.size).to eq(OeCheckGame::PLAYERS)
    end
    expect(@stock_states.size).to be > 0
  end
end
