# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/view"
require "oe/legal_actions"
require "oe/bot_runner"

# #125: a step that offers an action type without a generator (for example
# double_head_trains) must not break the state call or a bot move.
RSpec.describe "unsupported action types (#125)" do
  let(:game) { Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 1, seed: 1) }
  let(:step) { game.round.active_step }
  let(:viewer) { game.active_players.first.id }

  before do
    real = step.method(:actions)
    allow(step).to receive(:actions) { |entity| real.call(entity) + %w[brand_new_action] }
  end

  it "skips the type, keeps the others and lists it" do
    legal = Oe::LegalActions.new(game, limit: 5)
    actions = legal.call
    expect(actions).not_to be_empty
    expect(legal.unsupported).to eq([format("%s: brand_new_action", step.class.name.split("::").last)])
  end

  it "renders the view with the type in prompt.unsupported and the rest of the actions" do
    view = Oe::View.render(game, viewer: viewer, log: nil)
    expect(view[:prompt][:unsupported].size).to eq(1)
    expect(view[:prompt][:actions]).not_to be_empty
    expect(view[:prompt][:types]).not_to be_nil
  end

  it "reports nothing for a viewer who is not to act" do
    view = Oe::View.render(game, viewer: nil, log: nil)
    expect(view[:prompt][:unsupported]).to eq([])
  end

  it "lists only types that really have no generator" do
    other = Engine::Game::G18OE::Game.new(%w[p0 p1 p2 p3], id: 2, seed: 2)
    legal = Oe::LegalActions.new(other)
    legal.call
    expect(legal.unsupported).to eq([])
  end
end
