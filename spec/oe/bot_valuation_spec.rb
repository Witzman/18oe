# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/bot"

# #313: what privates and minors are worth to the bot (Oe::Bot::Valuation),
# and the auction that uses it. Evidence for the numbers: 18oe-workshop
# notes/reference/bot-bewertung-313.md.
RSpec.describe Oe::Bot::Valuation do
  let(:game) { Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1) }
  let(:valuation) { described_class.new(game, Random.new(1)) }
  let(:schwer) { described_class::PROFILES[:schwer] } # no forgetting: deterministic
  let(:player) { game.players.first }

  def stellung(owned: [], cash: 1350, opponents: nil, floated: 0, players: 4, seat: 3)
    opponents ||= (1...players).map { |i| { id: "p#{i}", owned: [], cash: 1350 } }
    described_class::Stellung.new(player_id: "p0", cash: cash, owned: owned, opponents: opponents,
                                  players: players, regionals_floated: floated, regional_par: 90, seat: seat)
  end

  def company(sym) = game.company_by_id(sym)

  it "builds the position from a real game (cash, quota base, highest regional par 90)" do
    st = described_class::Stellung.from(game, player, game.round.active_step)
    expect(st.cash).to eq(1350)
    expect(st.players).to eq(4)
    expect(st.regional_par).to eq(90)
    expect(st.opponents.map { |o| o[:id] }).to eq(%w[p1 p2 p3])
  end

  it "values a private without ability at face value" do
    expect(valuation.value(company("RSC"), stellung, schwer)).to eq(20)
  end

  it "adds the ability on top of face value and keeps minors at most £180" do
    %w[BBE HMLC G K].each { |sym| expect(valuation.value(company(sym), stellung, schwer)).to be > company(sym).value }
    expect(valuation.value(company("G"), stellung, schwer)).to be <= 180
  end

  it "ranks by rule-derived ability: G and K above C; BBE above WS" do
    v = ->(sym) { valuation.value(company(sym), stellung, schwer) }
    expect(v["G"]).to be > v["C"]
    expect(v["K"]).to be > v["C"]
    expect(v["BBE"] - 100).to be > v["WS"] - 40
  end

  it "is symmetric in the synergy table and adds synergy with what the bot owns" do
    table = described_class::SYNERGY
    table.each { |(a, b), level| expect(table[[b, a]]).to eq(level) }
    plain = valuation.value(company("G"), stellung, schwer)
    with_bbe = valuation.value(company("G"), stellung(owned: %w[BBE]), schwer)
    expect(with_bbe - plain).to eq(20)
  end

  it "adds a share of the next player's synergy (deny), not the others'" do
    next_has = [{ id: "p1", owned: %w[BBE], cash: 1350 }, { id: "p2", owned: [], cash: 1350 }, { id: "p3", owned: [], cash: 1350 }]
    last_has = [{ id: "p1", owned: [], cash: 1350 }, { id: "p2", owned: [], cash: 1350 }, { id: "p3", owned: %w[BBE], cash: 1350 }]
    plain = valuation.value(company("G"), stellung, schwer)
    expect(valuation.value(company("G"), stellung(opponents: next_has), schwer)).to eq(plain + 10) # 0.5 x 20
    expect(valuation.value(company("G"), stellung(opponents: last_has), schwer)).to eq(plain)
  end

  it "prices in risk by profile: einfach ignores it, schwer subtracts most" do
    einfach = described_class::PROFILES[:einfach].dup.tap { |p| p.skip_chance = 0.0 }
    expect(valuation.value(company("A"), stellung, einfach)).to be > valuation.value(company("A"), stellung, schwer)
  end

  it "the quota turns privates above 10/N into bargains; minors above 12/N at face value" do
    full = stellung(owned: %w[RSC PeC WS]) # ceil(10/4) = 3 privates
    expect(valuation.value(company("BBE"), full, schwer)).to eq(50)
    minors = stellung(owned: %w[A B C]) # ceil(12/4) = 3 minors
    expect(valuation.value(company("G"), minors, schwer)).to eq(120)
  end

  it "keeps the reserve for its share of the 18 regional floats, in whole regionals (duty)" do
    st = stellung # 4p, last seat: 18 = 4 x 4 + 2, seats 0 and 1 plan 5, seats 2 and 3 plan 4
    expect(valuation.reserve(st)).to eq(720) # 4 x 2 x 90
    expect(valuation.reserve(stellung(seat: 0))).to eq(900)
    expect(valuation.affordable?(630, st)).to be(true)
    expect(valuation.affordable?(635, st)).to be(false)
    expect(valuation.reserve(stellung(floated: 4))).to eq(0)
    expect((0..3).sum { |seat| valuation.planned_regionals(stellung(seat: seat)) }).to eq(18)
    expect((0..4).sum { |seat| valuation.planned_regionals(stellung(players: 5, seat: seat)) }).to eq(18)
  end

  it "fits terrain abilities to the best zone that still has a track-rights chit" do
    expect(valuation.zone_fit(:rough)).to eq(1.0)
    game.minor_available_regions.delete("AH") # mountains: AH is the best zone on the map
    expect(valuation.zone_fit(:rough)).to be_between(0.5, 0.95)
    expect(valuation.zone_fit(nil)).to eq(1.0)
  end

  it "reads the zone facts from the map: most mountains in AH, most water in RU" do
    facts = described_class::MapFacts.for(game)
    expect(facts.max_by { |_, f| f[:rough] }.first).to eq("AH")
    expect(facts.max_by { |_, f| f[:water] }.first).to eq("RU")
    expect(facts.keys).to contain_exactly(*%w[UK SC FR PHS AH IT SP RU])
  end

  describe "in the auction" do
    it "buys from the top row at face value and keeps its reserve through the whole packet" do
      bot = Oe::Bot.new(game, rng: Random.new(1))
      reserve = described_class.new(game, Random.new(1)).reserve(stellung) # lower of the two plans
      count = 0
      while game.round.is_a?(Engine::Round::Auction) && count < 2000
        pl = game.active_players.find { |p| !bot.legal_actions(p.id).empty? }
        game.process_action(bot.choose(player_id: pl.id))
        raise game.exception if game.exception

        count += 1
      end
      expect(game.round).not_to be_a(Engine::Round::Auction)
      minors = game.companies.select { |c| game.company_becomes_minor?(c) }
      expect(minors.map(&:owner)).to all(be_a(Engine::Player))
      # no player went below its float reserve, except by forced free items
      expect(game.players.map(&:cash)).to all(be >= reserve - 60)
    end
  end
end
