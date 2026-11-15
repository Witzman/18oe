# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/fixture_catalog"

# Fixture catalog (#117): playable game states from action logs, one or more per rule
# surface. Each entry is replayed to its position and checked: the engine is where the
# catalog says (round, step), the view renders and survives JSON, the enumerator offers
# something, and offered actions are accepted on a copy.
RSpec.describe Oe::FixtureCatalog do
  let(:catalog) { described_class.catalog }
  let(:entries) { described_class.entries }

  it "is well formed: unique names, known logs, positions inside the logs, every entry says where it is" do
    expect(entries.map(&:name).uniq.size).to eq(entries.size)
    entries.each do |e|
      expect(catalog["games"]).to have_key(e.game), e.name
      expect(e.surface.to_s).not_to be_empty
      expect(e.slice).to match(/\AS[1-9]\z/)
      expect(e.expect.keys).to include("round"), "#{e.name} has no expectation"
      expect(e.position).to be_between(0, catalog["games"][e.game]["actions"]), e.name
    end
    catalog["games"].each_value { |g| expect(File).to exist(File.join(described_class::DIR, g["file"])) }
    catalog["gaps"].each { |gap| expect(gap["reason"].to_s).not_to be_empty }
  end

  it "has an entry for every S1 round type of the engine's game flow" do
    rounds = entries.map { |e| e.expect["round"] }.uniq
    expect(rounds).to include("Auction", "Concession", "Stock", "Operating")
  end

  it "names an unknown entry clearly" do
    expect { described_class.entry("nope") }.to raise_error(KeyError, /nope/)
  end

  it "reports a wrong expectation" do
    entry = described_class.entry("auction-start")
    other = entry.dup
    other.expect = { "round" => "Operating" }
    expect(described_class.expectation_errors(other, described_class.game_at(entry))).not_to be_empty
  end

  Oe::FixtureCatalog.entries.each do |entry|
    it "plays #{entry.name} (#{entry.surface})", :game_flow do
      findings = described_class.check(entry, max_actions: 6)

      expect(described_class.problems(findings)).to be_empty
    end
  end
end
