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
end
