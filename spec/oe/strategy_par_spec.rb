# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/strategy_player"

# #308: the par target must stay reachable (regional par is 60..90, so 2 x par <= 180).
RSpec.describe Oe::StrategyPlayer do
  let(:game) { Engine::Game::G18OE::Game.new(%w[p0 p1 p2], id: 1, seed: 1) }
  let(:player) { described_class.new(game, rng: Random.new(1)) }
  let(:regionals) { game.corporations.select { |c| c.type == :regional } }
  let(:par_prices) { game.stock_market.par_prices.map(&:price) }
  let(:par_action) { Struct.new(:corporation, :share_price) }

  def options_for(corporation)
    game.stock_market.par_prices.map { |sp| par_action.new(corporation, sp) }
  end

  it "has regional par prices up to 90" do
    expect(par_prices.max).to eq(90)
  end

  it "picks a par for every regional (target never above 2 x highest par)" do
    expect(regionals).not_to be_empty
    regionals.each do |corporation|
      pick = player.send(:pick_par, options_for(corporation), {})
      expect(pick).not_to be_nil, "#{corporation.id}: no par picked (target #{player.send(:target_par, corporation)})"
      expect(pick.share_price.price).to be_between(par_prices.min, par_prices.max)
    end
  end

  it "takes par 90 when the wish is 200" do
    corporation = regionals.find { |c| player.send(:target_par, c) > 2 * par_prices.max }
    skip "no regional wants more than 180" unless corporation
    pick = player.send(:pick_par, options_for(corporation), {})
    expect(pick.share_price.price).to eq(90)
  end
end
