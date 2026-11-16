# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/fixture_catalog"
require "oe/invariants"

# Invariants (#138): rules the engine must never break, run over every catalog state (#117)
# and over states of a replayed log. Each check also has one deliberately broken state, so
# the check is proven to see a violation (test of the test).
RSpec.describe Oe::Invariants do
  def game(name)
    Oe::FixtureCatalog.game_at(name)
  end

  def violations(game, check)
    described_class.run(game, only: check)
  end

  it "names every check with a rulebook paragraph and a text" do
    expect(described_class::CHECKS.map(&:name).uniq.size).to eq(described_class::CHECKS.size)
    described_class::CHECKS.each do |c|
      expect(c.rule.to_s).not_to be_empty
      expect(c.text.to_s).not_to be_empty
    end
    expect(described_class.report).to include("money_conserved", "§3.3")
  end

  describe "over the catalog", :game_flow do
    Oe::FixtureCatalog.entries.each do |entry|
      it "holds at #{entry.name}" do
        found = described_class.failures(described_class.run(Oe::FixtureCatalog.game_at(entry)))

        expect(found.map(&:to_s)).to be_empty
      end
    end
  end

  describe "over a replayed log", :game_flow do
    %w[strategy-4p-1 random-4p-1].each do |name|
      it "holds at every 10th action of the whole #{name} log" do
        found = described_class.check_log(Oe::FixtureCatalog.log_file(name), every: 10)

        expect(found.reject { |_, v| v.pending }.map { |pos, v| "#{pos}: #{v}" }).to be_empty
      end
    end
  end

  # Every example below replays a catalog log (game_at, 1483 to 2531 actions), so the group is
  # :game_flow (#365). Fast variants that build the state by code come with the scenario helpers (slice 9).
  describe "each check sees one deliberately broken state", :game_flow do
    it "money_conserved: a note out of nowhere" do
      g = game("operating-dividend")
      expect(violations(g, :money_conserved)).to be_empty
      g.bank.add_cash(5)
      expect(violations(g, :money_conserved).map(&:message).join).to match(/expected 54000/)
    end

    it "money_conserved: allows the remainder cash only once it was added" do
      g = game("operating-dividend")
      g.bank.add_cash(described_class::REMAINDER_CASH)
      expect(violations(g, :money_conserved)).not_to be_empty
      g.instance_variable_set(:@remainder_cash_added, true)
      expect(violations(g, :money_conserved)).to be_empty
    end

    it "no_negative_cash: a company in debt (sum unchanged)" do
      g = game("operating-dividend")
      corp = g.corporations.find { |c| c.cash.positive? }
      other = g.players.first
      corp.spend(corp.cash + 5, other, check_cash: false)
      expect(violations(g, :money_conserved)).to be_empty
      expect(violations(g, :no_negative_cash).map(&:message).join).to include("#{corp.name} has -5")
    end

    it "shares_total_100: a certificate with the wrong size" do
      g = game("stock-first")
      share = g.players.flat_map(&:shares).first
      share.percent += 10
      expect(violations(g, :shares_total_100).map(&:message).join).to include(share.corporation.name)
    end

    it "shares_single_holder: one certificate in two portfolios" do
      g = game("stock-first")
      share = g.players.flat_map(&:shares).first
      g.players.find { |pl| pl != share.owner }.shares_by_corporation[share.corporation] << share
      expect(violations(g, :shares_single_holder)).not_to be_empty
    end

    it "president_holds_presidency: a president without stock" do
      g = game("stock-first")
      corp = g.corporations.find { |c| c.ipoed && c.owner&.player? }
      stranger = g.players.find { |pl| pl.percent_of(corp).zero? }
      corp.owner = stranger
      expect(violations(g, :president_holds_presidency).map(&:message).join).to include(corp.name)
    end

    it "certificate_limit: a player above the limit while another one acts in a stock round" do
      g = game("stock-first")
      expect(g.round.stock?).to be(true)
      expect(violations(g, :certificate_limit)).to be_empty
      g.instance_variable_set(:@cert_limit, 1)
      expect(violations(g, :certificate_limit)).not_to be_empty
    end

    it "train_supply: a train missing from the Locomotive Works" do
      g = game("operating-buy-train")
      expect(violations(g, :train_supply)).to be_empty
      train = g.depot.trains.first
      g.depot.trains.delete(train)
      expect(violations(g, :train_supply).map(&:message).join).to match(/rulebook has/)
    end

    it "train_limit: a company with more trains than the phase allows" do
      g = game("operating-buy-train")
      corp = g.corporations.find { |c| c.floated? && !c.closed? }
      expect(violations(g, :train_limit)).to be_empty
      corp.trains.concat(g.depot.upcoming.first(g.train_limit(corp) + 1 - corp.trains.size))
      expect(violations(g, :train_limit).map(&:message).join).to include(corp.name)
    end

    it "train_limit: a pending discard step may exceed it" do
      g = game("merge-discard-train")
      expect(g.round.active_step.class.name).to include("Discard")
      expect(violations(g, :train_limit)).to be_empty
    end

    it "tokens_consistent: the same token on two cities" do
      g = game("operating-token")
      expect(violations(g, :tokens_consistent)).to be_empty
      cities = g.hexes.flat_map { |h| h.tile.cities }
      tokened = cities.find { |c| c.tokens.compact.any? }
      free = cities.find { |c| c != tokened && c.tokens.size > 0 && c.tokens.compact.empty? }
      free.tokens[0] = tokened.tokens.compact.first
      expect(violations(g, :tokens_consistent).map(&:message).join).to match(/twice/)
    end

    it "tiles_consistent: one tile on two hexes" do
      g = game("operating-route")
      expect(violations(g, :tiles_consistent)).to be_empty
      laid = g.hexes.find { |h| !h.tile.preprinted }
      other = g.hexes.find { |h| h != laid && !h.tile.cities.empty? }
      other.instance_variable_set(:@tile, laid.tile)
      expect(violations(g, :tiles_consistent).map(&:message).join).to match(/two hexes/)
    end

    it "tiles_consistent: more tiles of one kind laid than the supply has" do
      g = game("merge-discard-train")
      expect(violations(g, :tiles_consistent)).to be_empty
      stub_const("Engine::Game::G18OE::Game::TILES", g.class::TILES.merge("8" => 1))
      expect(violations(g, :tiles_consistent).map(&:message).join).to match(/tiles named 8 laid/)
    end

    it "stock_market_positions: a price marker off the market" do
      g = game("stock-sell")
      corp = g.corporations.find(&:share_price)
      corp.share_price.instance_variable_set(:@coordinates, [99, 0])
      expect(violations(g, :stock_market_positions).map(&:message).join).to include("off the market")
    end
  end
end
