# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/fixture_catalog"
require "oe/fixture_builder"
require "tmpdir"

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

  # #365 B1: finders are resolved when the catalog is loaded; both formats are read.
  describe "finder entries" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        File.write(File.join(dir, "log.json"), JSON.generate("players" => 4, "seed" => 1, "actions_log" => []))
        example.run
      end
    end

    def write_catalog(entries)
      games = { "g" => { "file" => "log.json", "players" => 4, "seed" => 1, "actions" => 0 } }
      File.write(File.join(@dir, "catalog.json"), JSON.generate("games" => games, "entries" => entries, "gaps" => []))
    end

    def base(name, extra)
      { "name" => name, "surface" => "x", "slice" => "S1", "game" => "g" }.merge(extra)
    end

    it "resolves a finder to a position and expectation without replaying a stored position" do
      write_catalog([base("start", "at" => 0), base("auction", "first" => { "round" => "Auction" })])
      start, auction = described_class.entries(@dir)

      expect([start.position, auction.position]).to eq([0, 0])
      expect(auction.expect).to include("round" => "Auction", "step" => "WaterfallAuction")
      expect(auction.finder).to eq("first" => { "round" => "Auction" })
    end

    it "still reads the stored format (position and expect)" do
      write_catalog([base("old", "position" => 0, "expect" => { "round" => "Auction" })])
      old = described_class.entry("old", @dir)

      expect([old.position, old.finder, old.state]).to eq([0, nil, nil])
      expect(described_class.expectation_errors(old, described_class.game_at(old, @dir))).to be_empty
    end

    it "says which finder matched nothing" do
      write_catalog([base("never", "first" => { "round" => "Operating" })])

      expect { described_class.entries(@dir) }
        .to raise_error(RuntimeError, /finder never matched nothing in g \(0 actions\)/)
    end

    it "finds any state by round and step, or nil" do
      write_catalog([base("a", "first" => { "round" => "Auction", "step" => "WaterfallAuction" })])

      expect(described_class.find(round: "Auction", step: "WaterfallAuction", dir: @dir).name).to eq("a")
      expect(described_class.find(round: "Auction", phase: described_class.entry("a", @dir).state["phase"], dir: @dir)&.name).to eq("a")
      expect(described_class.find(round: "Auction", phase: "nope", dir: @dir)).to be_nil
      expect(described_class.find(round: "Stock", dir: @dir)).to be_nil
    end

    it "resolves once per catalog and log" do
      write_catalog([base("a", "at" => 0)])
      allow(described_class).to receive(:scan).and_call_original
      2.times { described_class.entries(@dir) }

      expect(described_class).to have_received(:scan).once
    end
  end

  # One-off proof for the move of the definition (#365 B1): resolving the builder's finders on
  # the stored logs gives the positions and expectations catalog.json holds today.
  it "resolves every finder of the definition to the stored position", :game_flow do
    stored = described_class.entries.to_h { |e| [e.name, e] }
    definition = Oe::FixtureBuilder::DEFINITION["entries"]
    expect(definition.map { |e| e["name"] }).to eq(stored.keys)

    resolved = definition.group_by { |e| e["game"] }.flat_map do |game_name, list|
      described_class.scan(described_class.log_file(game_name), list).to_a
    end.to_h
    definition.each do |e|
      expect(resolved[e["name"]]).to include(position: stored[e["name"]].position, expect: stored[e["name"]].expect), e["name"]
    end
  end

  Oe::FixtureCatalog.entries.each do |entry|
    it "plays #{entry.name} (#{entry.surface})", :game_flow do
      findings = described_class.check(entry, max_actions: 6)

      expect(described_class.problems(findings)).to be_empty
    end
  end
end
