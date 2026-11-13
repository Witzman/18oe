# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "oe/legal_actions"
require "oe/strategy_player"
require "json"

# #122: operating order and player priority in the view, checked against the
# sequence of `current` corporations of each operating round.
RSpec.describe "Oe::View order (#122)" do
  def json(view) = JSON.parse(JSON.generate(view))

  it "lists the players in priority order with the priority deal first, and no operating order before the majors" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    meta = Oe::View.render(game, actions: false)[:meta]
    expect(meta[:priority]).to eq(%w[p0 p1 p2 p3])
    expect(meta[:operating_order]).to eq([])
    expect(json(meta)["priority"]).to eq(%w[p0 p1 p2 p3])
  end

  it "matches the actual operating sequence of every operating round and the next stock round's order (strategy game)" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    rng = Random.new(1)
    strategist = Oe::StrategyPlayer.new(game, rng: rng)
    rounds = 0
    announced = nil
    seen = []
    count = 0
    last_priority = nil
    until game.finished || count > 20_000
      view = Oe::View.render(game, actions: false, log: nil)
      meta = view[:meta]
      order = meta[:operating_order]
      expect(meta[:priority].sort).to eq(game.players.map(&:id).sort)
      expect(order.map { |o| o[:id] }).to eq(game.operating_order.map(&:id)) unless meta[:round][:type] == "operating"
      if meta[:round][:type] == "operating"
        key = [meta[:round][:turn], meta[:round][:number]]
        if key != announced
          unless announced.nil?
            expect(seen.uniq).to eq(announced_ids.select { |id| seen.include?(id) }), "round #{announced}"
            rounds += 1
          end
          announced = key
          announced_ids = order.map { |o| o[:id] }
          seen = []
        end
        expect(order.map { |o| o[:id] }).to eq(announced_ids)
        cur = meta[:current]
        if cur && cur[:kind] == "corporation"
          i = order.index { |o| o[:id] == cur[:id] }
          expect(i).not_to be_nil
          expect(order.map { |o| o[:done] }).to eq(order.each_index.map { |j| j < i })
          seen << cur[:id]
        end
      end
      last_priority = meta[:priority]
      acts = Oe::LegalActions.new(game, limit: 8, rng: rng).call
      break if acts.empty?

      game.process_action(strategist.choose(acts) || acts.sample(random: rng))
      count += 1
    end
    expect(rounds).to be >= 2
    expect(last_priority).not_to be_nil
  end

  it "puts the player after the last to act first during a stock round" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1)
    rng = Random.new(1)
    strategist = Oe::StrategyPlayer.new(game, rng: rng)
    checked = 0
    count = 0
    until game.finished || count > 8000
      if game.round.is_a?(Engine::Round::Stock)
        prio = Oe::View.render(game, actions: false, log: nil)[:meta][:priority]
        expect(prio.first).to eq(game.priority_deal_player.id)
        expect(prio.size).to eq(4)
        checked += 1
      end
      acts = Oe::LegalActions.new(game, limit: 8, rng: rng).call
      break if acts.empty?

      game.process_action(strategist.choose(acts) || acts.sample(random: rng))
      count += 1
    end
    expect(checked).to be > 0
  end
end
