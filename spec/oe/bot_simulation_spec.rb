# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/bot_simulation"

RSpec.describe Oe::BotSimulation do
  def sim(**opts)
    described_class.new(**{ players: 4, seed: 1, max_actions: 150 }.merge(opts))
  end

  it "alternates bot and opponent seats, starting kind depends on the seed parity" do
    expect(sim(seed: 1).kinds_for.values).to eq(%i[random bot random bot])
    expect(sim(seed: 2).kinds_for.values).to eq(%i[bot random bot random])
    expect(sim(seed: 1, opponent: :strategy).kinds_for.values).to eq(%i[strategy bot strategy bot])
  end

  it "seats only bots with mix: :bots" do
    expect(sim(mix: :bots).kinds_for.values.uniq).to eq([:bot])
  end

  it "plays up to the action cap and reports plain figures" do
    result = sim.run
    expect(result.status).to eq(:limit)
    expect(result.actions).to eq(150)
    expect(result.values.keys.sort).to eq(%w[p0 p1 p2 p3])
    expect(result.moves.values.sum).to eq(150)
    expect(result.floated.keys).to eq(%w[minor regional major national])
    expect(result.winner_kind).to be_a(Symbol)
    expect(result.mean_value(:bot)).to be_a(Float)
    expect(result.to_h.keys).to include("players", "values", "passes")
  end

  it "is reproducible for a seed" do
    a = sim(seed: 3).run
    b = sim(seed: 3).run
    expect([a.values, a.moves, a.passes]).to eq([b.values, b.moves, b.passes])
  end

  it "plays a strategy opponent without an illegal action" do
    result = sim(opponent: :strategy, max_actions: 300).run
    expect(result.status).to eq(:limit)
    expect(result.kinds.values).to include(:strategy)
  end
end
