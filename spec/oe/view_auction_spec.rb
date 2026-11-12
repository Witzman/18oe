# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "json"

# The auction section of the view (#120), checked against the engine's waterfall
# auction step at the start and in the middle of the auction.
RSpec.describe "Oe::View auction (#120)" do
  let(:game) { Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1) }
  let(:step) { game.round.active_step }

  def view = Oe::View.auction(game)

  def bid(player, id, price)
    game.process_action(Engine::Action::Bid.new(game.player_by_id(player), company: game.company_by_id(id), price: price))
  end

  def pass(player)
    game.process_action(Engine::Action::Pass.new(game.player_by_id(player)))
  end

  # Everyone buys the top-row card at its minimum until a minor is in the top row.
  def advance_to_minor_row
    until game.company_becomes_minor?(step.companies.first)
      company = step.companies.first
      bid(game.current_entity.id, company.id, step.min_bid(company))
    end
  end

  it "lists all 32 cards in row order at the start, with the step's minimum bid" do
    v = view
    expect(v[:cards].size).to eq(32)
    expect(v[:cards].size).to eq(step.companies.size)
    expect(v[:cards].map { |c| c[:id] }).to eq(step.companies.map(&:id))
    expect(v[:cards].map { |c| c[:row] }).to eq(v[:cards].map { |c| c[:row] }.sort)
    expect(v[:cards].map { |c| c[:min_bid] }).to eq(step.companies.map { |c| step.min_bid(c) })
    expect(v[:cards].map { |c| c[:kind] }.tally).to eq("private" => 10, "minor" => 12, "concession" => 10)
    expect(v).to include(top_row: 1, increment: 5, current: nil, to_act: ["p0"], passed: [], open_bidders: [])
    expect(v[:cards].first).to eq(id: "PeC", name: "Ponts et Chaussees", kind: "private", row: 1, value: 20,
                                  revenue: 5, discount: 0, min_bid: 20, bid: nil)
    expect(v[:cards].map { |c| c[:bid] }.compact).to be_empty
  end

  it "is small and plain JSON" do
    expect(JSON.generate(view).bytesize).to be < 10_000
    expect(JSON.parse(JSON.generate(view))).to eq(JSON.parse(JSON.generate(view)))
  end

  it "drops sold cards and shows bids on lower rows" do
    bid("p0", "PeC", 20)
    v = view
    expect(v[:cards].size).to eq(31)
    expect(v[:cards].map { |c| c[:id] }).not_to include("PeC")
    expect(v[:to_act]).to eq(["p1"])

    bid("p1", "BBBT", 40) # not in the top row: only a bid, the card stays
    v = view
    expect(v[:cards].size).to eq(31)
    card = v[:cards].find { |c| c[:id] == "BBBT" }
    expect(card[:bid]).to eq(player: "p1", price: 40)
    expect(card[:min_bid]).to eq(step.min_bid(game.company_by_id("BBBT")))
    expect(card[:min_bid]).to eq(45)
  end

  it "reports who passed and the all-pass reduction of the top row" do
    pass("p0")
    expect(view[:passed]).to eq(["p0"])
    expect(view[:to_act]).to eq(["p1"])
    3.times { |i| pass("p#{i + 1}") }
    v = view
    expect(v[:passed]).to eq([]) # an all-pass resets the passes
    top = v[:cards].select { |c| c[:row] == 1 }
    expect(top.map { |c| [c[:discount], c[:min_bid]] }).to eq([[5, 15], [5, 15]])
    expect(v[:cards].reject { |c| c[:row] == 1 }.map { |c| c[:discount] }.uniq).to eq([0])
    expect(top.map { |c| c[:min_bid] }).to eq(top.map { |c| step.min_bid(game.company_by_id(c[:id])) })
  end

  it "shows the open auction of a minor: current card, high bid, who is still in" do
    advance_to_minor_row
    minor = step.companies.first
    expect(view[:cards].size).to eq(step.companies.size)
    expect(view[:cards].size).to eq(32 - 10) # the ten privates of rows 1-4 are sold
    opener = game.current_entity.id
    bid(opener, minor.id, minor.min_bid + 5)
    v = view
    expect(v[:current]).to eq(minor.id)
    expect(v[:cards].find { |c| c[:id] == minor.id }[:bid]).to eq(player: opener, price: minor.min_bid + 5)
    expect(v[:cards].find { |c| c[:id] == minor.id }[:min_bid]).to eq(minor.min_bid + 10)
    expect(v[:open_bidders]).to match_array(%w[p0 p1 p2 p3])
    expect(v[:to_act]).to eq(step.active_entities.map(&:id))
    expect(v[:to_act]).not_to include(opener)

    next_up = v[:to_act].first
    pass(next_up)
    expect(view[:open_bidders]).not_to include(next_up)
  end

  it "is nil once the auction is over" do
    expect(Oe::View.render(game, actions: false)[:auction]).not_to be_nil
    guard = 0
    while game.round.is_a?(Engine::Round::Auction) && (guard += 1) < 500
      company = step.companies.first
      if game.company_becomes_minor?(company)
        pass(game.current_entity.id) # all pass: the top row gets cheaper until it is free
      else
        bid(game.current_entity.id, company.id, step.min_bid(company))
      end
    end
    expect(game.round).not_to be_a(Engine::Round::Auction)
    expect(Oe::View.render(game, actions: false)[:auction]).to be_nil
  end
end
