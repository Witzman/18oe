# frozen_string_literal: true

require "engine"

RSpec.describe "18OE engine smoke" do
  # Starting cash per player as computed by the engine (STARTING_CASH).
  # Rulebook 3.3: 5,400 / players rounded up to 5 (standard); 5,200 without
  # concessions. The 2-player game has no concessions, hence 2,600 (not 2,700).
  STARTING_CASH = { 2 => 2600, 3 => 1800, 4 => 1350, 5 => 1080, 6 => 900, 7 => 775 }.freeze
  # 10 concessions are removed in the 2-player game.
  COMPANIES = { 2 => 22, 3 => 32, 4 => 32, 5 => 32, 6 => 32, 7 => 32 }.freeze

  def new_game(count)
    Engine::Game::G18OE::Game.new(("A".."Z").first(count), id: 1)
  end

  it "is registered under its title" do
    expect(Engine.game_by_title("18OE")).to eq(Engine::Game::G18OE::Game)
  end

  (2..7).each do |count|
    describe "with #{count} players" do
      let(:game) { new_game(count) }
      let(:step) { game.round.active_step }

      it "starts in the waterfall auction" do
        expect(game.round).to be_a(Engine::Round::Auction)
        expect(game.round.class).to eq(Engine::Round::Auction)
        expect(step).to be_a(Engine::Game::G18OE::Step::WaterfallAuction)
        expect(step.current_actions).to eq(%w[bid pass])
      end

      it "has the expected entities and cash" do
        expect(game.players.size).to eq(count)
        expect(game.corporations.size).to eq(36)
        expect(game.companies.size).to eq(COMPANIES.fetch(count))
        expect(game.players.map(&:cash)).to all(eq(STARTING_CASH.fetch(count)))
      end
    end
  end

  describe "first actions" do
    let(:game) { new_game(4) }

    it "lets the first player pass" do
      first = game.current_entity
      game.process_action(Engine::Action::Pass.new(first))

      expect(game.exception).to be_nil
      expect(game.current_entity).not_to eq(first)
      expect(game.round.class).to eq(Engine::Round::Auction)
    end

    it "lets the first player buy a top-row company at face value" do
      first = game.current_entity
      step = game.round.active_step
      company = step.companies.min_by(&:auction_row)
      price = step.min_bid(company)
      game.process_action(Engine::Action::Bid.new(first, company: company, price: price))

      expect(game.exception).to be_nil
      expect(company.owner).to eq(first)
      expect(first.cash).to eq(1350 - price)
    end
  end
end
