# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"

# #568 (#563 Task 4b): the track/token families in Chris' action formats: place_token with token_index and cost,
# transfer tokens (slot), special_buy (Port Authority), assign (Hochberg, Minor D). Scenarios follow the
# upstream specs (transfer_tokens_spec, hochberg_spec, port_authority_spec); every offered action must be
# accepted by the engine on a fresh copy of the scenario.
RSpec.describe Oe::LegalActions, "track and token formats" do
  include G18OESpecHelpers

  def operating_round_for(game, entity)
    round = enter_round!(game, game.operating_round(1))
    round.entities = [entity]
    round.instance_variable_set(:@current_operator, entity)
    round
  end

  # Applies an offered action (as a hash, like a stored log line) to a fresh scenario through the round.
  def accepted?(build, action)
    hash = action.to_h.dup.tap { action.clear_cache }
    game = build.call
    game.process_action(hash)
    game.exception.nil?
  end

  describe "hochberg: assign with a hex target" do
    let(:build) do
      lambda do
        game = new_game
        player = game.players.first
        give_company!(player, game.company_by_id("HMLC"))
        rr = start_major!(game, "LNWR", player)
        fund!(game, rr, 700)
        operating_round_for(game, rr)
        game
      end
    end

    it "offers assign to the owner's RR and the engine accepts every offered hex" do
      game = build.call
      assigns = described_class.new(game, limit: 6).call.grep(Engine::Action::Assign)

      expect(assigns).not_to be_empty
      expect(assigns.map { |a| a.target.class }.uniq).to eq([Engine::Hex])
      assigns.each { |action| expect(accepted?(build, action)).to be(true), action.to_h.inspect }
    end
  end

  describe "transfer tokens: place_token with slot, token_index and cost" do
    let(:build) do
      lambda do
        game = new_game
        player = game.players.first
        buyer = start_major!(game, "LNWR", player)
        seller = start_major!(game, "GWR", player)
        fund!(game, buyer, 700)
        christiania = game.hex_by_id("C48").tile.cities.first
        christiania.exchange_token(seller.tokens.find { |t| !t.used && t.price == 60 })
        [game, buyer]
      end
    end

    it "offers every transfer with the charter token and its cost, and the step accepts each" do
      game, buyer = build.call
      round = operating_round_for(game, buyer)
      step = round_step(round, Engine::Game::G18OE::Step::TransferTokens)
      offers = described_class.new(game, limit: 20).send(:generate_place_token, step, buyer)

      expect(offers).not_to be_empty
      expect(offers).to all(satisfy { |a| a.slot.is_a?(Integer) && a.token_index.is_a?(Integer) && a.cost.is_a?(Integer) })
      offers.each do |action|
        fresh_game, fresh_buyer = build.call
        fresh_step = round_step(operating_round_for(fresh_game, fresh_buyer), Engine::Game::G18OE::Step::TransferTokens)
        copy = Engine::Action::Base.action_from_h(action.to_h.dup.tap { action.clear_cache }, fresh_game)
        expect { fresh_step.process_place_token(copy) }.not_to raise_error, action.to_h.inspect
      end
    end
  end

  describe "port authority: special_buy" do
    let(:build) do
      lambda do
        game = new_game
        rr = start_major!(game, "LNWR", game.players.first)
        fund!(game, rr, 700)
        operating_round_for(game, rr)
        game
      end
    end

    it "offers the buyable port authorities as special_buy and the engine accepts them" do
      game = build.call
      buys = described_class.new(game, limit: 20).call.grep(Engine::Action::SpecialBuy)

      expect(buys).not_to be_empty
      buys.each { |action| expect(accepted?(build, action)).to be(true), action.to_h.inspect }
    end
  end

  describe "swift metropolitan line: choose_ability" do
    let(:build) do
      lambda do
        game = new_game
        player = game.players.first
        give_company!(player, game.company_by_id("SML"))
        minor = start_minor!(game, "K", player, "RU")
        major = start_major!(game, "LNWR", player)
        game.phase.next! until game.phase.available?("4")
        2.times { game.buy_train(minor, game.depot.upcoming.find { |t| t.name == "2+2" }, :free) }
        game.rust_trains!(game.depot.upcoming.find { |t| t.name == "4" }, minor)
        operating_round_for(game, major)
        game
      end
    end

    it "offers the ability's choice to the owner and the engine accepts it" do
      game = build.call
      abilities = described_class.new(game, limit: 6).call.grep(Engine::Action::ChooseAbility)

      expect(abilities.map { |a| a.choice }).to eq(["preserve"])
      abilities.each { |action| expect(accepted?(build, action)).to be(true), action.to_h.inspect }
    end
  end

  describe "pullman: a depot train with its own price, and the add-on choice in the route step" do
    let(:build) do
      lambda do
        game = new_game
        player = game.players.first
        major = start_major!(game, "LNWR", player)
        fund!(game, major, 900)
        game.phase.next! until game.phase.available?("4")
        game.depot.depot_trains(clear: true)
        game.buy_train(major, game.depot.upcoming.find { |t| t.name == "4" }, :free)
        [game, major]
      end
    end

    it "offers a Pullman from the depot at a price the buy step accepts" do
      game, major = build.call
      step = round_step(operating_round_for(game, major), Engine::Game::G18OE::Step::BuyTrain)
      offers = described_class.new(game, limit: 40).send(:generate_buy_train, step, major)
      pullmans = offers.select { |a| game.pullman?(a.train) }

      expect(pullmans).not_to be_empty
      pullmans.each do |action|
        fresh_game, fresh_major = build.call
        fresh_step = round_step(operating_round_for(fresh_game, fresh_major), Engine::Game::G18OE::Step::BuyTrain)
        copy = Engine::Action::Base.action_from_h(action.to_h.dup.tap { action.clear_cache }, fresh_game)
        expect { fresh_step.process_buy_train(copy) }.not_to raise_error, action.to_h.inspect
      end
    end

    it "offers the Pullman's attachment to a train as a choose in the route step" do
      game, major = build.call
      game.buy_train(major, game.depot.upcoming.find { |t| game.pullman?(t) }, :free)
      round = operating_round_for(game, major)
      act!(game, Engine::Action::Pass.new(major)) until round.active_step.is_a?(Engine::Game::G18OE::Step::Route)
      choices = described_class.new(game, limit: 10).send(:generate_choose, round.active_step, major)

      expect(choices.map(&:choice)).to include(a_string_matching(/\Apullman:/))
    end
  end
end
