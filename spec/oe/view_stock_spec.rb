# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "oe/legal_actions"

# #47: `prompt.context.stock` gives the money of every offered buy/sell bundle. Checked against what the engine
# does when the action is played: the cash that moves and the share price after a sale.
RSpec.describe "Oe::View stock context (#47)" do
  G = Engine::Game::G18OE

  it "names cost, proceeds and new price of the offered bundles as the engine charges them" do
    checked = { "buy_shares" => 0, "sell_shares" => 0, "price" => 0, "par" => 0 }
    [1, 2].each do |seed|
      game = G::Game.new(%w[p0 p1 p2], id: seed, seed: seed)
      rng = Random.new(seed)
      800.times do
        break if game.finished

        action = nil

        step = game.round.active_step
        acts = Oe::LegalActions.new(game, limit: 10, rng: rng).call
        break if acts.empty?

        view = Oe::View.render(game, viewer: game.active_players.first&.id, log: nil)
        stock = view[:prompt][:context][:stock]
        unless step.is_a?(G::Step::BuySellParShares)
          expect(stock).to be_nil
          game.process_action(acts.sample(random: rng))
          next
        end

        shares = acts.select { |a| a.is_a?(Engine::Action::BuyShares) || a.is_a?(Engine::Action::SellShares) }
        pars = acts.select { |a| a.is_a?(Engine::Action::Par) }
        expect(stock[:bundles].size).to eq(shares.size)
        expect(stock[:pars].size).to eq(pars.size)
        action = pars.sample(random: rng) if rng.rand < 0.4
        if action.is_a?(Engine::Action::Par)
          offer = stock[:pars].find { |x| x[:corporation] == action.corporation.id && x[:share_price] == action.share_price.id }
          expect(offer).not_to be_nil
          cash = action.entity.cash
          game.process_action(action)
          expect(cash - action.entity.cash).to eq(offer[:price])
          checked["par"] += 1
          next
        end
        action = shares.sample(random: rng) || acts.sample(random: rng)
        bundle = action.respond_to?(:bundle) && action.bundle &&
                 stock[:bundles].find { |b| b[:shares] == action.bundle.shares.map(&:id) && b[:type] == action.type }
        entity = action.entity
        cash = entity.cash
        corp = action.bundle&.corporation if bundle
        game.process_action(action)
        next unless bundle

        delta = entity.cash - cash
        if bundle[:type] == "buy_shares"
          expect(-delta).to eq(bundle[:price]) unless entity.cash == cash && game.round.active_step.is_a?(G::Step::ReserveShare)
        else
          expect(delta).to eq(bundle[:price])
          expect(corp.share_price.price).to eq(bundle[:new_price]) if bundle[:new_price]
          checked["price"] += 1
        end
        checked[bundle[:type]] += 1
      end
    end
    expect(checked["buy_shares"]).to be > 0
    expect(checked["par"]).to be > 0
  end
end
