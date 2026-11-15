# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/bot"
require "oe/legal_actions"

# #321: Bot::Track values an upgrade by the yield it adds (stop revenue of the new
# tile minus the old one in the current phase) when the network reaches the stop.
RSpec.describe Oe::Bot::Track, "yield of upgrades" do
  include G18OESpecHelpers

  # Phase 3 (yellow and green), LNWR operating with track around London (as #315's test).
  let(:game) do
    g = new_game(%w[a b c])
    g.players.each_with_index { |_p, i| start_major!(g, %w[LNWR PLM SFAI][i], g.players[i]) }
    g.corporations.select { |c| c.type == :major }.each { |major| fund!(g, major, 700) }
    g.phase.next!
    enter_round!(g, g.operating_round(1))
    g
  end
  let(:entity) { game.round.active_step.current_entity }
  let(:track) { described_class.new(game, Random.new(1)) }
  let(:lays) { track.send(:all_lays, entity) }

  def scored
    track.send(:score_all, entity, lays).map { |s, a| [a.hex.id, a.tile.name, a.rotation, s] }
  end

  def gain(action)
    graph = game.graph_for_entity(entity)
    track.send(:yield_gain, action.hex, action.tile, graph.connected_nodes(entity))
  end

  it "gains yield only where the old stop is in the reached network" do
    gains = lays.to_h { |a| [[a.hex.id, a.tile.name, a.rotation], gain(a)] }
    expect(gains.values.max).to be_positive
    reached = game.graph_for_entity(entity).connected_nodes(entity)
    lays.each do |a|
      next if a.hex.tile.city_towns.any? { |n| reached[n] }

      expect(gain(a)).to eq(0), "#{a.hex.id} is off the network but earns a yield gain"
    end
  end

  it "scores a yield upgrade above the same lay without the yield term, and above pass" do
    gainer = lays.find { |a| gain(a).positive? }
    key = [gainer.hex.id, gainer.tile.name, gainer.rotation]
    with = scored.find { |*k, _| k.first(3) == key }.last
    stub_const("Oe::Bot::Track::YIELD_WEIGHT", 0)
    without = described_class.new(game, Random.new(1)).send(:score_all, entity, [gainer]).first.first
    expect(with).to be > without
    expect(with - without).to eq(gain(gainer) * 2)
    expect(with).to be_positive
  end

  it "does not score an upgrade off the network or without a gain as progress by yield" do
    flat = lays.select { |a| gain(a).zero? }
    expect(flat).not_to be_empty
    stub_const("Oe::Bot::Track::YIELD_WEIGHT", 100)
    with_weight = described_class.new(game, Random.new(1)).send(:score_all, entity, flat).map(&:first)
    stub_const("Oe::Bot::Track::YIELD_WEIGHT", 0)
    without = described_class.new(game, Random.new(1)).send(:score_all, entity, flat).map(&:first)
    expect(with_weight).to eq(without)
  end

  it "prefers a yield upgrade to pass" do
    gainer = lays.find { |a| gain(a).positive? }
    pass = Struct.new(:entity).new(entity)
    only = [Engine::Action::LayTile.new(entity, tile: gainer.tile, hex: gainer.hex, rotation: gainer.rotation)]
    allow(track).to receive(:all_lays).and_return(only)
    by_class = { "LayTile" => only, "Pass" => [pass] }
    picks = Array.new(20) { described_class.new(game, Random.new(_1)).tap { |t| allow(t).to receive(:all_lays).and_return(only) }.choose(by_class) }
    expect(picks).to all(be_a(Engine::Action::LayTile))
  end
end
