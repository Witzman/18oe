# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/view"
require "oe/bot"

# #53: forming nationals (§9.4) at the first train of Train Phase 4, 6, 8. The
# player decides (Chris' format, #563): `choose <major id>` per major, and `choose done`.
RSpec.describe Oe::LegalActions, "national formation" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:alice) { game.players[0] }
  let!(:lnwr) { start_major!(game, "LNWR", alice) }
  let!(:gwr) { start_major!(game, "GWR", alice) }
  let(:round) { enter_round!(game, game.operating_round(1)) }

  before do
    round
    game.phase.next!
    train = game.depot.upcoming.find { |t| t.name == "4" }
    game.buy_train(lnwr, train, :free)
    game.phase.buying_train!(lnwr, train, game.depot)
  end

  it "offers a choose per major of the player and done" do
    actions = described_class.call(game)

    expect(actions.map { |a| [a.type, a.entity.id, a.choice] }).to contain_exactly(%w[choose a LNWR], %w[choose a GWR], %w[choose a done])
  end

  it "offers the remaining majors after a conversion, and the engine accepts each offer" do
    act!(round, Engine::Action::Choose.new(alice, choice: "GWR"))
    offers = described_class.call(game)

    expect(offers.map(&:choice)).to contain_exactly("LNWR", "done")
    offers.each do |offer|
      game.process_action(offer.to_h.dup.tap { offer.clear_cache })
      expect(game.exception).to be_nil, offer.choice
      break
    end
  end

  it "names the step, its help and the pass in the prompt" do
    prompt = Oe::View.render(game, viewer: alice.id)[:prompt]

    expect(prompt[:step]).to eq("FormNational")
    expect(prompt[:description]).to eq("Form Nationals")
    # Chris' Step::FormNational has no help text; the player text is the UI's (text.ts).
    expect(prompt[:help]).to be_nil
    expect(prompt[:pass_description]).to eq("Pass")
    expect(prompt[:unsupported]).to be_empty
    expect(prompt[:acting_as].map { |a| a[:entity] }).to contain_exactly("a")
  end

  it "lets the bot decline until nationals operate (#64)" do
    action = Oe::Bot.new(game, rng: Random.new(1)).choose(player_id: alice.id)

    expect(action).to be_a(Engine::Action::Choose)
    expect(action.choice).to eq("done")
    expect(action.entity).to eq(alice)
  end
end
