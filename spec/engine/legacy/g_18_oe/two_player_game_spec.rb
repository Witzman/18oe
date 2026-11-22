# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# PB 5.4 "Two Player Full Game" (PDF p. 14): no concessions; up to 70 % of a major or national instead of
# 60 % (§10.2); the Aggressive Game rules of PB 5.5 apply, so §11.1.9 Right-of-Way and §8.4 reserved shares
# fall away. Each rule has its own detailed spec; this one pins them together for one two-player game and
# plays the opening rounds (#499). Details: two_player_ownership_spec (70 %), right_of_way_spec (two-player
# contexts), reserved_shares_spec ('is unavailable with two players'), setup_spec (cash, concessions).
describe 'G18OE two-player full game (PB 5.4)' do
  include G18OESpecHelpers

  let(:game) { new_game(%w[a b]) }
  let(:three) { new_game }

  it 'holds all four two-player rules together' do
    expect(
      starting_cash: game.players.map(&:cash),
      concessions: game.companies.count { |c| c.type == :concession },
      major_cap: game.major_max_ownership_percent,
      right_of_way: game.right_of_way_rules?,
      reserved_shares: game.reserved_shares?
    ).to eq(starting_cash: [2600, 2600], concessions: 0, major_cap: 70, right_of_way: false, reserved_shares: false)
  end

  it 'keeps the full-game rules with three players' do
    expect(
      concessions: three.companies.count { |c| c.type == :concession },
      major_cap: three.major_max_ownership_percent,
      right_of_way: three.right_of_way_rules?,
      reserved_shares: three.reserved_shares?
    ).to eq(concessions: 10, major_cap: 60, right_of_way: true, reserved_shares: true)
  end

  describe 'opening rounds without concessions' do
    # Each player in turn takes the first company on offer at its minimum price, until the auction ends.
    def run_auction!
      40.times do
        break unless game.round.is_a?(Engine::Round::Auction)

        step = game.round.active_step
        player = game.round.current_entity
        company = step.available.first
        act!(game, Engine::Action::Bid.new(player, company: company, price: step.min_bid(company)))
      end
    end

    it 'sells all 22 privates and minors in the auction and goes straight to the Stock Round' do
      run_auction!

      expect(
        round: game.round.class,
        step: game.round.active_step.class,
        sold: game.players.sum { |p| p.companies.size }
      ).to eq(round: Engine::Round::Stock, step: Engine::Game::G18OE::Step::BuySellParShares, sold: 22)
    end

    it 'lets the first player in the Stock Round par a company' do
      run_auction!
      round = game.round

      expect(round.current_entity.name).to eq('a')
      expect(round.actions_for(round.current_entity)).to include('par')
    end
  end
end
