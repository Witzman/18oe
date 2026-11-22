# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/script_game"
require "oe/view"

# #224: the S2 target list (lib/oe/script_game/slices/s2.yml): conversions, merges and train discards.
# A target is only listed if the enumerator offers it in a state a small scenario reaches, under the key
# the script game counts (ScriptGame#key, round/step/type). Each scenario below builds that state with the
# scenario helpers (#365) and names the keys it proves; the spec fails for a target without a scenario and
# for a scenario key that is no target. That the whole script game reaches the targets is shown only by a
# run of `bin/script-game --slice s2` (CI), not here.
RSpec.describe "S2 target list, conversions, merges and train discards (#224)" do
  include G18OESpecHelpers

  let(:slice) { Oe::ScriptGame.slice("s2") }
  let(:unreachable) { slice.fetch("unreachable") }
  let(:targets) { slice.fetch("games").flat_map { |g| g["combos"] } }
  let(:script) { Oe::ScriptGame.new(clients: {}, slice: "s2").tap { |s| s.instance_variable_set(:@mirror, game) } }
  let(:game) { new_game }

  # The keys the script game would count for what the enumerator offers now.
  def offered_keys
    round = Oe::View.round_type(game.round)
    step = game.round.active_step.class.name.split("::").last
    Oe::LegalActions.new(game, limit: 12, rng: Random.new(1)).call.map do |action|
      script.key(round, step, JSON.parse(JSON.generate(action.to_h)))
    end.uniq
  end

  # A stock round from Train Phase 3, where a minor may merge into a major (§10.5).
  def merge_round!
    allow(game).to receive(:major_phase?).and_return(true)
    game.phase.next!
    stock_round!(game)
  end

  def merge!(round, owner, minor, major)
    act!(round, Engine::Action::Choose.new(owner, choice: minor.id))
    act!(round, Engine::Action::Merge.new(minor, corporation: major))
  end

  def pass_all!(round, klass)
    act!(round, Engine::Action::Pass.new(round.active_step.current_entity)) while round.active_step.is_a?(klass)
  end

  # key => the keys that scenario proves (the first state it reaches is the one the keys are read from)
  SCENARIOS = {
    "stock convert" => %w[stock/BuySellParShares/convert],
    "stock offer to the other presidents" => %w[stock/BuySellParShares/choose:offer_or_merge],
    "stock merge" => %w[stock/MergeMinor/merge],
    "stock merge offer" => %w[stock/MergeOffer/choose:merge_offer stock/MergeOffer/pass],
    "stock merge token" => %w[stock/MergeToken/place_token stock/MergeToken/pass],
    "stock merge train" => %w[stock/MergeDiscardTrain/discard_train stock/MergeDiscardTrain/pass],
    "consolidation" => %w[consolidation/Consolidate/convert],
    "consolidation abandon" => %w[consolidation/Consolidate/choose:offer_or_abandon],
    "consolidation offer" => %w[consolidation/Consolidate/choose:offer_or_merge],
    "consolidation answer" => %w[consolidation/MergeOffer/choose:merge_offer consolidation/MergeOffer/pass],
    "national formation" => %w[operating/FormNational/choose:convert operating/FormNational/choose:done],
    "lower train limit" => %w[operating/DiscardTrain/discard_train],
  }.freeze

  def scenario_keys(name)
    send("state_#{name.tr(' ', '_')}")
    offered_keys
  end

  def state_stock_convert
    allow(game).to receive(:major_phase?).and_return(true)
    round = stock_round!(game)
    start_regional!(game, "LNWR", round.current_entity)
  end

  def state_stock_offer_to_the_other_presidents
    round = merge_round!
    start_minor!(game, "B", round.current_entity, "SP")
    start_major!(game, "LNWR", game.players.last)
  end

  def state_stock_merge
    round = merge_round!
    owner = round.current_entity
    start_major!(game, "LNWR", owner)
    act!(round, Engine::Action::Choose.new(owner, choice: start_minor!(game, "B", owner, "SP").id))
  end

  def state_stock_merge_offer
    round = merge_round!
    owner = round.current_entity
    start_major!(game, "LNWR", game.players.last)
    act!(round, Engine::Action::Choose.new(owner, choice: "offer_or_merge", target: start_minor!(game, "B", owner, "SP")))
  end

  def state_stock_merge_token
    round = merge_round!
    owner = round.current_entity
    major = start_major!(game, "LNWR", owner)
    minor = start_minor!(game, "B", owner, "SP")
    game.hex_by_id("Q38").tile.cities.first.place_token(minor, minor.next_token, free: true, check_tokenable: false)
    merge!(round, owner, minor, major)
  end

  def state_stock_merge_train
    round = merge_round!
    owner = round.current_entity
    major = start_major!(game, "LNWR", owner)
    minor = start_minor!(game, "B", owner, "SP")
    game.buy_train(minor, game.depot.upcoming.first, :free)
    merge!(round, owner, minor, major)
    pass_all!(round, Engine::Game::G18OE::Step::MergeToken)
  end

  # A minor's owner without a regional may offer it to the other presidents (§10.6); a president of a
  # regional has to convert it first; one with a major of its own may merge (the offer is then to the others).
  def consolidation_round!(regional_owner: 1, own_major: false)
    start_major!(game, "GWR", game.players[0]) if own_major
    allow(game).to receive(:major_phase?).and_return(true)
    game.instance_variable_set(:@turn, 2)
    start_regional!(game, "LNWR", game.players[regional_owner])
    start_minor!(game, "B", game.players[0], "SP")
    start_major!(game, "PLM", game.players[2])
    game.phase.next!
    enter_round!(game, game.new_consolidation_round)
  end

  def state_consolidation
    consolidation_round!(regional_owner: 0)
  end

  def state_consolidation_abandon
    consolidation_round!
  end

  def state_consolidation_offer
    consolidation_round!(own_major: true)
  end

  def state_consolidation_answer
    consolidation_round!(own_major: true)
    act!(game.round, Engine::Action::Choose.new(game.players[0], choice: "offer_or_merge", target: game.corporation_by_id("B")))
  end

  def state_national_formation
    alice = game.players[0]
    lnwr = start_major!(game, "LNWR", alice)
    enter_round!(game, game.operating_round(1))
    game.phase.next!
    train = game.depot.upcoming.find { |t| t.name == "4" }
    game.buy_train(lnwr, train, :free)
    game.phase.buying_train!(lnwr, train, game.depot)
  end

  def state_lower_train_limit
    at_phase!(game, "3")
    major = start_major!(game, "LNWR", game.players[0])
    with_trains!(game, major, "3", "3", "3", "3")
    game.fulfill_train_obligation!(major)
    operating_round_for!(game, 1)
    at_phase!(game, "4")
    # Chris' FormNational window comes before the discard step; the player declines it.
    act!(game.round, Engine::Action::Choose.new(game.players[0], choice: "done")) if game.national_formation_player
  end

  SCENARIOS.each do |name, keys|
    it "#{name}: the enumerator offers #{keys.join(', ')}" do
      expect(scenario_keys(name)).to include(*keys)
    end
  end

  it "has a scenario for every target and every unreachable key, and for nothing else" do
    expect(SCENARIOS.values.flatten.sort).to eq((targets + unreachable.keys).sort)
  end

  it "keeps a key out of the targets when it is named unreachable, with a reason (#481)" do
    expect(targets & unreachable.keys).to be_empty
    expect(unreachable.values).to all(match(/#118/))
  end
end
