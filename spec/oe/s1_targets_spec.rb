# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/script_game"

# #421: the S1 target list (lib/oe/script_game/slices/s1.yml) follows the forced train purchase of a
# major as #354 implemented it (§11.6.4): the president may not sell shares in the Buy Trains step any
# more (EBUY_CAN_SELL_SHARES = false), so `operating/BuyTrain/sell_shares:major` cannot be a target; a
# major whose treasury and president cannot pay converts into a national with `bankrupt`, offered in
# the Buy Trains step. Each operating/BuyTrain target of the rush game must be an action the enumerator
# offers in such a state, under the key the script game counts (ScriptGame#key, round/step/type).
RSpec.describe "S1 target list, forced train purchase of a major (§11.6.4, #421)" do
  include G18OESpecHelpers

  let(:slice) { Oe::ScriptGame.slice("s1") }
  let(:rush) { slice.fetch("games").find { |g| g["rush"] } }
  let(:script) { Oe::ScriptGame.new(clients: {}, slice: "s1") }

  let(:game) { new_game }
  let(:alice) { game.players[0] }
  let!(:lnwr) { start_major!(game, "LNWR", alice) }
  let(:round) { at_phase!(game, "4") && operating_round_for!(game, 1) }

  def operate!(corporation)
    round.instance_variable_set(:@entity_index, round.entities.index(corporation))
    round.instance_variable_set(:@current_operator, corporation)
    round.steps.each do |s|
      break if s.is_a?(Engine::Game::G18OE::Step::BuyTrain)

      s.pass! unless s.is_a?(Engine::Game::G18OE::Step::FormNational) || s.is_a?(Engine::Step::Bankrupt)
    end
  end

  # The keys the script game would count for what the enumerator offers now (prompt step = active step).
  def offered_keys
    step = game.round.active_step.class.name.split("::").last
    Oe::LegalActions.new(game, limit: 12, rng: Random.new(1)).call.map do |action|
      script.key("operating", step, JSON.parse(JSON.generate(action.to_h)))
    end.uniq
  end

  it "no longer asks for a share sale by the president in the Buy Trains step" do
    expect(slice.fetch("games").flat_map { |g| g["combos"] }).not_to include("operating/BuyTrain/sell_shares:major")
  end

  it "asks for the conversion of a major that cannot pay, and the enumerator offers it under that key" do
    expect(rush["combos"]).to include("operating/BuyTrain/choose:national")

    lnwr.set_cash(10, game.bank)
    alice.set_cash(50, game.bank)
    operate!(lnwr)

    expect(offered_keys).to include("operating/BuyTrain/choose:national")
    expect(offered_keys.grep(/sell_shares/)).to be_empty
  end
end
