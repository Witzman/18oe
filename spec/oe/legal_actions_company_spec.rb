# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/view"

# #128: a private acts as its own entity (White Cliffs Ferry places a token in
# Lille at the token step of a corporation its owner controls). The engine
# keeps that in a non-blocking step (SpecialToken); the enumerator offers it.
RSpec.describe Oe::LegalActions, "private company actions" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:owner) { game.players[0] }
  let(:other) { game.players[1] }
  let(:lille) { game.hex_by_id("N31").tile.cities.first }
  let(:phase) { "5" }
  let(:operator) { start_major!(game, "LNWR", owner) }
  let(:wcf) { give_company!(owner, game.company_by_id("WCF")) }
  let(:round) do
    operator
    wcf
    game.phase.next! until game.phase.name == phase
    game.minor_regional_order.delete(operator)
    game.minor_regional_order.unshift(operator)
    r = enter_round!(game, game.operating_round(1))
    r.setup
    round_step(r, Engine::Step::Track).pass!
    r
  end

  def company_places(actions)
    actions.select { |a| a.is_a?(Engine::Action::PlaceToken) && a.entity.company? }
  end

  it "offers the White Cliffs Ferry token to the owner of the operating RR from phase 5" do
    fund!(game, operator, 200)
    expect(round.current_operator).to eq(operator)
    places = company_places(described_class.new(game).call)

    expect(places.map { |a| a.city }).to eq([lille])
    expect(places.first.to_h["tokener"]).to eq("LNWR")
  end

  it "is accepted by the engine" do
    fund!(game, operator, 200)
    round
    action = company_places(described_class.new(game).call).first
    act!(round, action)
    expect(lille.tokened_by?(operator)).to be(true)
    expect(wcf.closed?).to be(true)
    expect(company_places(described_class.new(game).call)).to eq([])
  end

  it "offers the token also with Lille full (extra position)" do
    fund!(game, operator, 200)
    blocker = start_regional!(game, "PLM", other)
    round
    fund!(game, operator, 200)
    lille.place_token(blocker, blocker.next_token, free: true)
    places = company_places(described_class.new(game).call)
    expect(places.map(&:city)).to eq([lille])
    act!(round, places.first)
    expect(lille.extra_tokens.map(&:corporation)).to eq([operator])
  end

  context "before phase 5" do
    let(:phase) { "4" }

    it "offers nothing" do
      round
      expect(company_places(described_class.new(game).call)).to eq([])
    end
  end

  it "offers nothing to a player who does not control the operating RR" do
    other_op = start_major!(game, "LNWR", other)
    round
    wcf
    expect(other_op).not_to eq(nil)
    expect(company_places(described_class.new(game).call)).to eq([])
  end

  it "appears in the owner's prompt, labelled as a company" do
    fund!(game, operator, 200)
    round
    prompt = Oe::View.render(game, viewer: owner.id)[:prompt]
    acts = prompt[:actions].select { |a| a["entity_type"] == "company" && a["type"] == "place_token" }
    expect(acts.size).to eq(1)
    expect(prompt[:acting_as].map { |a| [a[:entity], a[:kind], a[:primary]] }).to include(["WCF", "company", false])
  end

  it "is authorized for its owner only (games API, acting for the operating RR)" do
    require "oe/games_api"
    api = Object.new.extend(Oe::GamesApi::Helpers)
    round
    expect(api.acting_for?(game, owner.id, "WCF")).to be(true)
    expect(api.acting_for?(game, other.id, "WCF")).to be(false)
  end

  it "is not offered to bots (they do not use privates yet)" do
    round
    require "oe/bot"
    actions = Oe::Bot.new(game, rng: Random.new(1)).legal_actions(owner.id)
    expect(company_places(actions)).to eq([])
  end
end
