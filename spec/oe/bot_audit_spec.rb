# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/bot_audit"

RSpec.describe Oe::BotAudit do
  let(:game) { Engine::Game::G18OE::Game.new(%w[p0 p1 p2], id: 1, seed: 1) }
  let(:baseline) { described_class::Invariants.total_cash(game) }

  def check = described_class::Invariants.check(game, baseline)

  it "finds no violation in a fresh game" do
    expect(check).to eq([])
  end

  it "reports a changed cash total (money created or lost)" do
    baseline
    p0 = game.players.first; p0.send(:cash=, p0.cash + 10)
    expect(check.join).to include("cash total")
  end

  it "reports negative player cash and a certificate overrun" do
    baseline
    player = game.players.first
    player.send(:cash=, -5)
    allow(game).to receive(:num_certs).and_call_original
    allow(game).to receive(:num_certs).with(player).and_return(game.cert_limit(player) + 1)
    msgs = check
    expect(msgs.join).to include("cash -5 < 0").and include("certs")
  end

  it "reports a corporation whose shares do not add up to 100%" do
    baseline
    corp = game.corporations.first
    allow(corp).to receive(:ipoed).and_return(true)
    allow(corp).to receive(:share_holders).and_return({ corp => 60 })
    expect(check.join).to include("shares sum 60% != 100%")
  end

  it "plays a capped game with fixed seed and reports plain figures, no findings" do
    result = described_class.run(players: 3, seed: 1, max_actions: 120)
    expect(result.status).to eq(:limit)
    expect(result.actions).to eq(120)
    expect(result.findings).to eq([])
    expect(result.steps.values.sum { |s| s[:offered] }).to eq(120)
    expect(described_class.run(players: 3, seed: 1, max_actions: 120).steps.keys).to eq(result.steps.keys)
  end
end
