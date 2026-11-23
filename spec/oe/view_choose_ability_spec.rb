# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require_relative "../support/view_checks"
require "oe/view"
require "oe/legal_actions"

# #563 (RB 14.4 (1)): in its RR's OR the owner of Barclay, Bevan, Barclay and Tritton re-sets the par value through
# the private's choose_ability (Chris' Step::SpecialChoose, Patch 0016). The prompt lists each offered choice with a
# label of its own and the step's texts, like a `choose`; the engine accepts every offered action.
RSpec.describe Oe::View, "choose_ability choices (RB 14.4)" do
  include G18OESpecHelpers
  include OeViewChecks

  let(:game) { new_game }
  let(:owner) { game.players[0] }
  let(:bbbt) { game.company_by_id("BBBT") }

  before do
    give_company!(owner, bbbt)
    operating_regional!(game, "LNWR", owner)
    operating_round_for!(game, 1, setup: true)
  end

  let(:prompt) { described_class.render(game, viewer: owner.id, log: nil)[:prompt] }
  let(:abilities) { prompt[:actions].select { |a| a["type"] == "choose_ability" } }

  it "offers the re-par values as choose_ability actions with a label each" do
    expect(abilities.map { |a| a["choice"] }).to eq(%w[65 70 75 80 90].map { |v| "bbbt_repar:#{v}" })
    expect(prompt[:choices].map { |c| c[:choice] }).to eq(abilities.map { |a| a["choice"] })
    expect(prompt[:choices].map { |c| c[:label] }).to all(match(/\ARe-Par LNWR: /))
  end

  it "passes the prompt text checks" do
    expect(prompt_text_errors(game, described_class.render(game, viewer: owner.id, log: nil))).to be_empty
  end

  it "has every offered re-par accepted by the engine" do
    action = Oe::LegalActions.new(game).call.find { |a| a.is_a?(Engine::Action::ChooseAbility) }
    game.process_action(action)
    expect(game.exception).to be_nil
    expect(bbbt).to be_closed
  end
end
