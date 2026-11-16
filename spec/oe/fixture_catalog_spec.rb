# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/fixture_catalog"
require "oe/fixture_builder"
require "stringio"
require "tmpdir"

# Fixture catalog (#117): playable game states from action logs, one or more per rule
# surface. Each entry is replayed to its position and checked: the engine is where the
# catalog says (round, step), the view renders and survives JSON, the enumerator offers
# something, and offered actions are accepted on a copy.
RSpec.describe Oe::FixtureCatalog do
  let(:catalog) { described_class.catalog }
  let(:entries) { described_class.entries }

  it "is well formed without a replay: games, unique names, finders, where names, after references, gaps" do
    expect(described_class.static_errors).to be_empty
    catalog["games"].each_value { |g| expect(File).to exist(File.join(described_class::DIR, g["file"])) }
  end

  it "reads the finders of the catalog without resolving them" do
    expect(entries.map(&:finder)).to all(be_a(Hash))
    expect(entries.map(&:name)).to include("auction-start", "auction-running", "game-end")
  end

  it "resolves auction-start without a replay (the start state)" do
    entry = described_class.entry("auction-start")

    expect([entry.position, entry.expect]).to eq([0, { "round" => "Auction", "step" => "WaterfallAuction" }])
  end

  describe ".static_errors" do
    let(:good) do
      { "games" => { "g" => { "file" => "g.json", "players" => 4, "seed" => 1, "player" => "random", "max_actions" => 10 } },
        "entries" => [{ "name" => "a", "surface" => "x", "slice" => "S1", "game" => "g", "at" => 0 },
                      { "name" => "b", "surface" => "x", "slice" => "S2", "game" => "g",
                        "first" => { "round" => "Auction" }, "where" => "bids_open", "after" => "a" }],
        "gaps" => [{ "surface" => "y", "reason" => "z" }] }
    end

    def with_entry(extra, index: 1)
      good.merge("entries" => good["entries"].each_with_index.map { |e, i| i == index ? e.merge(extra) : e })
    end

    it("accepts a good catalog") { expect(described_class.static_errors(good)).to be_empty }

    it "names each kind of defect" do
      {
        with_entry({ "name" => "a" }) => /name missing or twice/,
        with_entry({ "game" => "h" }) => /unknown game/,
        with_entry({ "slice" => "S10" }) => /slice/,
        with_entry({ "at" => 0 }) => /exactly one/,
        with_entry({ "first" => { "colour" => "red" } }) => /unknown keys/,
        with_entry({ "where" => "nope" }) => /unknown where/,
        with_entry({ "after" => "b" }) => /not an earlier entry/,
        with_entry({ "position" => 3 }) => /has a position/,
        with_entry({ "at" => 5 }, index: 0) => /at must be 0/,
        good.merge("gaps" => [{ "surface" => "y" }]) => /no reason/,
        good.merge("games" => { "g" => { "file" => "g.json" } }) => /no players, seed/,
      }.each do |catalog, message|
        expect(described_class.static_errors(catalog).join("\n")).to match(message), message.inspect
      end
    end
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

      entry = described_class.entries(@dir).first # reading the entry is free, asking for its position replays
      expect { entry.position }.to raise_error(RuntimeError, /finder never matched nothing in g \(0 actions\)/)
    end

    it "finds any state by round and step, or nil" do
      write_catalog([base("a", "first" => { "round" => "Auction", "step" => "WaterfallAuction" })])

      expect(described_class.find(round: "Auction", step: "WaterfallAuction", dir: @dir).name).to eq("a")
      expect(described_class.find(round: "Auction", phase: described_class.entry("a", @dir).state["phase"], dir: @dir)&.name).to eq("a")
      expect(described_class.find(round: "Auction", phase: "nope", dir: @dir)).to be_nil
      expect(described_class.find(round: "Stock", dir: @dir)).to be_nil
    end

    it "honours where and after (first bid on the auction, first state behind an earlier entry)" do
      log = JSON.parse(File.read(File.join(described_class::DIR, "strategy-4p-1.json")))
      File.write(File.join(@dir, "log.json"), JSON.generate(log.merge("actions_log" => log["actions_log"].first(2))))
      write_catalog([base("start", "at" => 0),
                     base("bid", "first" => { "round" => "Auction" }, "where" => "bids_open"),
                     base("later", "first" => { "round" => "Auction" }, "after" => "bid")])
      start, bid, later = described_class.entries(@dir)

      expect([start.position, bid.position, later.position]).to eq([0, 1, 2])
    end

    it "resolves once per catalog and log" do
      write_catalog([base("a", "at" => 0), base("b", "first" => { "round" => "Auction" })])
      allow(described_class).to receive(:scan).and_call_original
      2.times { described_class.entries(@dir).each(&:position) }

      expect(described_class).to have_received(:scan).twice # the start state, and one scan for the log
    end
  end

  # #365 B4: stale logs, live mode, rebuild and diff, on a tiny game of a few actions (no whole game).
  describe "stale logs, live mode, build and diff" do
    let(:game_spec) { { "file" => "log.json", "players" => 4, "seed" => 1, "player" => "random", "max_actions" => 3 } }
    let(:definition) do
      { "games" => { "g" => game_spec },
        "entries" => [{ "name" => "start", "surface" => "x", "slice" => "S1", "game" => "g", "at" => 0 },
                      { "name" => "late", "surface" => "x", "slice" => "S1", "game" => "g", "first" => { "round" => "Auction" }, "after" => "start" }],
        "gaps" => [] }
    end

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    def built(dir = @dir)
      Oe::FixtureBuilder.build(dir, definition, out: StringIO.new)
      JSON.parse(File.read(File.join(dir, "log.json")))
    end

    def store(log)
      File.write(File.join(@dir, "log.json"), JSON.generate(log))
    end

    it "builds one game of the catalog, deterministically, and keeps the others as they are" do
      first = built
      second = built(File.join(@dir, "again"))

      expect(second).to eq(first)
      expect(first["actions_log"].size).to be_between(1, 3)
      other = definition.merge("games" => definition["games"].merge("h" => game_spec.merge("file" => "h.json")))
      Oe::FixtureBuilder.build(File.join(@dir, "one"), other, only: ["g"], out: StringIO.new)
      expect(File).not_to exist(File.join(@dir, "one", "h.json"))
      expect { Oe::FixtureBuilder.build(@dir, other, only: ["x"], out: StringIO.new) }.to raise_error(/unknown game x/)
    end

    it "says stale at which action when the stored log no longer fits the engine" do
      log = built.merge("actions_log" => described_class.play(game_spec).log)
      log["actions_log"][1] = log["actions_log"][1].merge("type" => "bid", "company" => "NOPE", "price" => 1)
      store(log)
      File.write(File.join(@dir, "catalog.json"), JSON.generate(definition.merge("entries" => [{ "name" => "x", "surface" => "x", "slice" => "S1", "game" => "g", "position" => 2, "expect" => {} }])))

      expect { described_class.game_at(described_class.entry("x", @dir), @dir) }
        .to raise_error(described_class::StaleLog, /log g stale at action 2 \(bid\).*needs a refresh/)
    end

    it "scans a stale stored log with the same message" do
      log = built
      log["actions_log"][0] = log["actions_log"][0].merge("company" => "NOPE")
      store(log)
      File.write(File.join(@dir, "catalog.json"), JSON.generate(definition))

      expect { described_class.entries(@dir).last.position }.to raise_error(described_class::StaleLog, /log g stale at action 1 /)
    end

    it "plays a fresh game instead of the stored log in live mode" do
      File.write(File.join(@dir, "catalog.json"), JSON.generate(definition))
      File.write(File.join(@dir, "log.json"), "not even json")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("OE_CATALOG").and_return("live")

      expect(described_class).to be_live
      expect(described_class.entries(@dir).map(&:position)).to eq([0, 1])
      expect(described_class.game_at("late", @dir).actions.size).to eq(1)
    end

    it "reports the first differing action and moved entries without writing" do
      log = built.merge("actions_log" => described_class.play(game_spec).log)
      store(log)
      File.write(File.join(@dir, "catalog.json"), JSON.generate(definition))
      same = Oe::FixtureBuilder.diff("g", @dir, definition)
      expect(same[:first_difference]).to be_nil
      expect(Oe::FixtureBuilder.report(same)).to include("logs: identical", "moved or unmatched: 0")

      log["actions_log"][1] = log["actions_log"][1].merge("price" => 999)
      store(log)
      changed = Oe::FixtureBuilder.diff("g", @dir, definition)
      expect(changed[:first_difference]).to eq(1)
      expect(Oe::FixtureBuilder.report(changed)).to include("first difference at action 2")
      expect(JSON.parse(File.read(File.join(@dir, "log.json")))).to eq(log)
    end

    it "finds the first differing action of two logs, ignoring ids and times" do
      a = [{ "type" => "pass", "id" => 1 }, { "type" => "bid", "id" => 2 }]

      expect(described_class.first_difference(a, [{ "type" => "pass", "id" => 9, "created_at" => 1 }, { "type" => "bid" }])).to be_nil
      expect(described_class.first_difference(a, [{ "type" => "pass" }, { "type" => "pass" }])).to eq(1)
      expect(described_class.first_difference(a, a.first(1))).to eq(1) # stored longer than fresh
      expect(described_class.first_difference(a.first(1), a)).to be_nil # stored cut after its last needed position
    end
  end

  it "resolves every entry inside its log and says where it is", :game_flow do
    entries.each do |e|
      expect(e.expect.keys).to include("round"), "#{e.name} has no expectation"
      expect(e.position).to be_between(0, catalog["games"][e.game]["actions"]), e.name
    end
  end

  it "has an entry for every S1 round type of the engine's game flow", :game_flow do
    rounds = entries.map { |e| e.expect["round"] }.uniq
    expect(rounds).to include("Auction", "Concession", "Stock", "Operating")
  end

  it "finds a state by round and step", :game_flow do
    expect(described_class.find(round: "Operating", step: "Dividend")&.name).to eq("operating-dividend")
  end

  Oe::FixtureCatalog.entries.each do |entry|
    it "plays #{entry.name} (#{entry.surface})", :game_flow do
      findings = described_class.check(entry, max_actions: 6)

      expect(described_class.problems(findings)).to be_empty
    end
  end
end
