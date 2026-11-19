# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/script_game"

# #235: action types of #132's rest list that the S1 script game does not ask for, because no reachable
# state of the game offers them (or none can be steered to). Each is named under `unreachable:` in
# lib/oe/script_game/slices/s1.yml with its reason; a target that is never reached turns the CI run red.
# What is checked here is the code fact behind the reason, on set-up states (no whole game).
RSpec.describe "S1 target list, types outside the strategy (#235)" do
  include G18OESpecHelpers

  let(:slice) { Oe::ScriptGame.slice("s1") }
  let(:combos) { slice.fetch("games").flat_map { |g| g["combos"] } }
  let(:script) { Oe::ScriptGame.new(clients: {}, slice: "s1") }
  let(:game) { new_game }
  let(:alice) { game.players[0] }

  def offered_keys(step_name, round: "operating")
    script.instance_variable_set(:@mirror, game)
    Oe::LegalActions.new(game, limit: 12, rng: Random.new(1)).call.map do |action|
      script.key(round, step_name, JSON.parse(JSON.generate(action.to_h)))
    end.uniq
  end

  def operate_until!(round, corporation, step_class)
    round.instance_variable_set(:@entity_index, round.entities.index(corporation))
    round.instance_variable_set(:@current_operator, corporation)
    round.steps.each do |s|
      break if s.is_a?(step_class)

      s.pass! unless s.is_a?(Engine::Game::G18OE::Step::ConvertToNational) || s.is_a?(Engine::Step::Bankrupt)
    end
  end

  it "names every type that is not a target, with a reason, and none of them is a target" do
    unreachable = slice.fetch("unreachable")
    expect(unreachable.keys).to include("stock/BuySellParShares/buy_company", "operating/BuyTrain/sell_shares:regional",
                                        "operating/IssueShares/sell_shares:minor", "operating/IssueShares/buy_shares:major", "skip", "operating/OrientExpressBonus/choose")
    expect(unreachable.values).to all(be_a(String).and(satisfy { |reason| reason.size > 20 }))
    expect(combos & unreachable.keys).to be_empty
  end

  it "has no bank-owned private to buy: nothing in the game hands a private to the bank" do
    expect(game.buyable_bank_owned_companies).to be_empty
    expect(Engine::Game::G18OE::Step::BuySellParShares.ancestors).not_to include(Engine::Step::BuySellParSharesCompanies)
    round = stock_round!(game)
    expect(round.active_step.buyable_bank_owned_companies(alice)).to be_empty
  end

  it "offers no share sale for a train, for any corporation type: the president may not sell (§11.6.4, #354)" do
    expect(Engine::Game::G18OE::Game::EBUY_CAN_SELL_SHARES).to be false
    major = start_major!(game, "LNWR", alice)
    at_phase!(game, "4")
    round = operating_round_for!(game, 1)
    major.set_cash(10, game.bank)
    alice.set_cash(50, game.bank)
    operate_until!(round, major, Engine::Game::G18OE::Step::BuyTrain)
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::BuyTrain)
    expect(round.active_step.actions(major)).not_to include("sell_shares")
  end

  it "lets only a major issue or redeem shares: IssueShares offers sell_shares:major and buy_shares:major" do
    major = start_major!(game, "LNWR", alice)
    at_phase!(game, "4")
    round = operating_round_for!(game, 1)
    with_trains!(game, major)
    fund!(game, major, 2000)
    operate_until!(round, major, Engine::Game::G18OE::Step::IssueShares)
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::IssueShares)
    game.share_pool.sell_shares(game.issuable_shares(major).first)

    keys = offered_keys("IssueShares")
    expect(keys).to include("operating/IssueShares/sell_shares:major", "operating/IssueShares/buy_shares:major")
    expect(keys.grep(/shares:(minor|regional)/)).to be_empty
    expect(game.corporations.reject { |c| c.type == :major }.flat_map { |c| game.issuable_shares(c) }).to be_empty
  end

  it "offers no redeem in the turn of an issue: selling passes the Issue step (#468)" do
    major = start_major!(game, "LNWR", alice)
    at_phase!(game, "4")
    round = operating_round_for!(game, 1)
    with_trains!(game, major)
    fund!(game, major, 2000)
    operate_until!(round, major, Engine::Game::G18OE::Step::IssueShares)
    step = round.active_step
    expect(step.actions(major)).to include("sell_shares")
    bundle = game.issuable_shares(major).first
    round.process_action(Engine::Action::SellShares.new(major, shares: bundle.shares, share_price: bundle.price, percent: bundle.percent))
    # selling passes the step at once: sell and redeem are never offered in one prompt of the same turn
    expect(round.active_step).not_to be_a(Engine::Game::G18OE::Step::IssueShares)
    expect(offered_keys("IssueShares")).not_to include("operating/IssueShares/buy_shares:major")
  end
end
