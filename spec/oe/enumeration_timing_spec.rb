# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/enumeration_timing"

# Structure only, no time limits (#87).
RSpec.describe Oe::EnumerationTiming do
  it "times full and bot enumeration per step on a short game and reports a table" do
    run = described_class.run(players: 3, seed: 1, max_actions: 200)
    expect(run[:actions]).to eq(200)
    expect(run[:samples]).not_to be_empty
    expect(run[:samples].first.step).to be_a(String)

    report = described_class.report(run[:samples])
    expect(report).to include("== full (limit nil) ==", "== bot (limit 12) ==", "median ms", "p95 ms", "max ms", "ALL")
    expect(described_class.rows(run[:samples]).first.size).to eq(7)
  end
end
