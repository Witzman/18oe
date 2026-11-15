# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"
require "oe/view"
require "oe/bot"

# #53: forming nationals (§9.4) at the first train of Train Phase 4, 6, 8. The
# player decides: `convert` per major (issued by the corporation, as the
# regional conversion of the stock round) and `pass`.
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

  it "offers a convert per major of the player and a pass" do
    actions = described_class.call(game)

    expect(actions.map { |a| [a.type, a.entity.id] }).to contain_exactly(%w[pass a], %w[convert LNWR], %w[convert GWR])
  end

  it "offers the remaining majors after a conversion" do
    act!(round, Engine::Action::Convert.new(gwr))
    expect(described_class.call(game).map { |a| [a.type, a.entity.id] }).to contain_exactly(%w[pass a], %w[convert LNWR])
  end

  it "names the step, its help and the pass in the prompt" do
    prompt = Oe::View.render(game, viewer: alice.id)[:prompt]

    expect(prompt[:step]).to eq("ConvertToNational")
    expect(prompt[:description]).to eq("Form Nationals")
    expect(prompt[:help]).to include("Train Phase 4", "LNWR", "GWR")
    expect(prompt[:pass_description]).to include("Done")
    expect(prompt[:unsupported]).to be_empty
    expect(prompt[:acting_as].map { |a| a[:entity] }).to contain_exactly("a", "LNWR", "GWR")
  end

  it "lets the bot decline until nationals operate (#64)" do
    action = Oe::Bot.new(game, rng: Random.new(1)).choose(player_id: alice.id)

    expect(action).to be_a(Engine::Action::Pass)
    expect(action.entity).to eq(alice)
  end
end
