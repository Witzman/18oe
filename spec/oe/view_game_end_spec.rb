# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"

# meta.game_end (#126): read from the engine's game_end_check state, no whole game needed.
RSpec.describe "Oe::View meta.game_end" do
  let(:game) { Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1) }

  def game_end(g = game)
    Oe::View.render(g, actions: false)[:meta][:game_end]
  end

  it "reports an untriggered game with the full bank" do
    ge = game_end
    expect(ge[:triggered]).to be(false)
    expect(ge[:reason]).to be_nil
    expect(ge[:timing]).to be_nil
    expect(ge[:remaining_ors]).to be_nil
    expect(ge[:bank]).to include(cash: game.bank.cash, starting: game.bank_starting_cash, broken: false)
    expect(ge[:bank][:share]).to be_between(0.0, 1.0).and eq((game.bank.cash.to_f / game.bank_starting_cash).round(4))
  end

  it "announces the bank break with the engine's timing" do
    game.bank.break!
    game.send(:game_end_check)
    ge = game_end
    expect(ge).to include(triggered: true, reason: "bank", timing: "current_or", remaining_ors: 1)
    expect(ge[:bank][:broken]).to be(true)
  end

  it "counts the operating rounds left for the final phase" do
    game.instance_variable_set(:@game_end_trigger, [:final_phase, :one_more_full_or_set])
    game.instance_variable_set(:@final_turn, game.turn + 1)
    ge = game_end
    expect(ge).to include(triggered: true, reason: "final_phase", timing: "one_more_full_or_set")
    expect(ge[:remaining_ors]).to be_a(Integer).and be_positive
  end

  it "keeps the reason after the game has ended" do
    game.bank.break!
    game.end_game!(:bank)
    expect(game_end).to include(triggered: true, reason: "bank", remaining_ors: 0)
  end
end
