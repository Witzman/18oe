# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/fixture_catalog"
require "oe/invariants"
require_relative "../engine/g_18_oe/helpers"

# Invariants (#138): rules the engine must never break, run over every catalog state (#117)
# and over states of a replayed log. Each check also has one deliberately broken state, so
# the check is proven to see a violation (test of the test).
RSpec.describe Oe::Invariants do
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

  # Each example builds its state by code (scenario building blocks of spec/engine/g_18_oe/helpers.rb, #365):
  # no catalog log is replayed. The first expectation of every example is that the check is silent on the
  # sound state, the second that it reports the one violation we introduce.
  describe "each check sees one deliberately broken state" do
    include G18OESpecHelpers

    # Two regionals, two share holders, a stock round on turn: every player in the game, no train bought.
    def stock_state
      g = new_game
      start_regional!(g, "LNWR", g.players[0])
      start_regional!(g, "GWR", g.players[1])
      stock_round!(g)
      g
    end

    # Phase 3, a regional that holds a train, an operating round entered: nothing is pending.
    def operating_state
      g = new_game
      at_phase!(g, "3")
      corp = operating_regional!(g, "LNWR", g.players[0])
      fund!(g, corp, 100)
      operating_round_for!(g, 1, setup: true)
      [g, corp]
    end

    it "money_conserved: a note out of nowhere" do
      g, = operating_state
      expect(violations(g, :money_conserved)).to be_empty
      g.bank.add_cash(5)
      expect(violations(g, :money_conserved).map(&:message).join).to match(/expected 54000/)
    end

    it "money_conserved: allows the remainder cash only once it was added" do
      g, = operating_state
      g.bank.add_cash(described_class::REMAINDER_CASH)
      expect(violations(g, :money_conserved)).not_to be_empty
      g.instance_variable_set(:@remainder_cash_added, true)
      expect(violations(g, :money_conserved)).to be_empty
    end

    it "no_negative_cash: a company in debt (sum unchanged)" do
      g, corp = operating_state
      expect(corp.cash).to be_positive
      expect(violations(g, :no_negative_cash)).to be_empty
      corp.spend(corp.cash + 5, g.players.first, check_cash: false)
      expect(violations(g, :money_conserved)).to be_empty
      expect(violations(g, :no_negative_cash).map(&:message).join).to include("#{corp.name} has -5")
    end

    it "shares_total_100: a certificate with the wrong size" do
      g = stock_state
      share = g.players.flat_map(&:shares).first
      expect(violations(g, :shares_total_100)).to be_empty
      share.percent += 10
      expect(violations(g, :shares_total_100).map(&:message).join).to include(share.corporation.name)
    end

    it "shares_single_holder: one certificate in two portfolios" do
      g = stock_state
      share = g.players.flat_map(&:shares).first
      expect(violations(g, :shares_single_holder)).to be_empty
      g.players.find { |pl| pl != share.owner }.shares_by_corporation[share.corporation] << share
      expect(violations(g, :shares_single_holder)).not_to be_empty
    end

    it "president_holds_presidency: a president without stock" do
      g = stock_state
      corp = g.corporations.find { |c| c.ipoed && c.owner&.player? }
      expect(violations(g, :president_holds_presidency)).to be_empty
      stranger = g.players.find { |pl| pl.percent_of(corp).zero? }
      corp.owner = stranger
      expect(violations(g, :president_holds_presidency).map(&:message).join).to include(corp.name)
    end

    it "certificate_limit: a player above the limit while another one acts in a stock round" do
      g = stock_state
      expect(g.round.stock?).to be(true)
      holder = g.players[1]
      take_treasury_shares!(g, holder, g.corporation_by_id("GWR"), 1)
      expect(g.round.current_entity).not_to eq(holder)
      expect(g.num_certs(holder)).to be > 1
      expect(violations(g, :certificate_limit)).to be_empty
      g.instance_variable_set(:@cert_limit, 1)
      expect(violations(g, :certificate_limit).map(&:message).join).to include("#{holder.name} holds")
    end

    it "train_supply: a train missing from the Locomotive Works" do
      g, = operating_state
      expect(violations(g, :train_supply)).to be_empty
      g.depot.trains.delete(g.depot.trains.find { |t| t.owner == g.depot })
      expect(violations(g, :train_supply).map(&:message).join).to match(/rulebook has/)
    end

    it "train_limit: a company with more trains than the phase allows" do
      g, corp = operating_state
      expect(violations(g, :train_limit)).to be_empty
      with_trains!(g, corp, *(["3"] * g.train_limit(corp)))
      expect(corp.trains.size).to be > g.train_limit(corp)
      expect(violations(g, :train_limit).map(&:message).join).to include(corp.name)
    end

    it "train_limit: a pending discard step may exceed it" do
      g = new_game
      at_phase!(g, "3")
      corp = operating_regional!(g, "LNWR", g.players[0])
      with_trains!(g, corp, *(["3"] * g.train_limit(corp)))
      expect(corp.trains.size).to be > g.train_limit(corp)
      # crowded_corps is read when the round is entered, so the trains come first.
      operating_round_for!(g, 1, setup: true)
      expect(g.round.active_step.class.name).to include("Discard")
      expect(violations(g, :train_limit)).to be_empty
      # The same crowd with a step that is not a discard step is the violation (proof the exemption is the step).
      allow(g.round).to receive(:active_step).and_return(g.round.steps.find { |s| s.class.name.include?("Track") })
      expect(violations(g, :train_limit)).not_to be_empty
    end

    it "tokens_consistent: the same token on two cities" do
      g, = operating_state
      expect(violations(g, :tokens_consistent)).to be_empty
      cities = g.hexes.flat_map { |h| h.tile.cities }
      tokened = cities.find { |c| c.tokens.compact.any? }
      free = cities.find { |c| c != tokened && c.tokens.size > 0 && c.tokens.compact.empty? }
      free.tokens[0] = tokened.tokens.compact.first
      expect(violations(g, :tokens_consistent).map(&:message).join).to match(/twice/)
    end

    it "tiles_consistent: one tile on two hexes" do
      g, = operating_state
      laid = lay_tile!(g, plain_hex(g), "8").hex
      expect(violations(g, :tiles_consistent)).to be_empty
      other = g.hexes.find { |h| h != laid && !h.tile.cities.empty? }
      other.instance_variable_set(:@tile, laid.tile)
      expect(violations(g, :tiles_consistent).map(&:message).join).to match(/two hexes/)
    end

    it "tiles_consistent: more tiles of one kind laid than the supply has" do
      g, = operating_state
      lay_tile!(g, plain_hex(g), "8")
      expect(violations(g, :tiles_consistent)).to be_empty
      stub_const("Engine::Game::G18OE::Game::TILES", g.class::TILES.merge("8" => 0))
      expect(violations(g, :tiles_consistent).map(&:message).join).to match(/tiles named 8 laid/)
    end

    it "reserved_shares_consistent: a reserved share left over after the initial stock round" do
      g = stock_state
      corp = g.corporation_by_id("LNWR")
      g.reserve_share!(corp)
      g.instance_variable_set(:@turn, 1)
      expect(violations(g, :reserved_shares_consistent)).to be_empty
      g.instance_variable_set(:@turn, 2)
      expect(violations(g, :reserved_shares_consistent).map(&:message).join).to match(/outside the initial stock round/)
    end

    it "reserved_shares_consistent: two shares reserved by one player" do
      g = stock_state
      g.instance_variable_set(:@turn, 1)
      lnwr = g.corporation_by_id("LNWR")
      gwr = g.corporation_by_id("GWR")
      g.reserve_share!(lnwr)
      g.reserve_share!(gwr)
      expect(violations(g, :reserved_shares_consistent)).to be_empty
      gwr.owner = lnwr.owner
      expect(violations(g, :reserved_shares_consistent).map(&:message).join).to match(/more than one/)
    end

    it "stock_market_positions: a price marker off the market" do
      g = stock_state
      corp = g.corporations.find(&:share_price)
      expect(violations(g, :stock_market_positions)).to be_empty
      corp.share_price.instance_variable_set(:@coordinates, [99, 0])
      expect(violations(g, :stock_market_positions).map(&:message).join).to include("off the market")
    end

    # A hex with no track at all, where a tile can be put without any legality question.
    def plain_hex(game)
      game.hexes.find { |h| h.tile.preprinted && h.tile.paths.empty? && h.tile.cities.empty? && h.tile.towns.empty? }
    end
  end
end
