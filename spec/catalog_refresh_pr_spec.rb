# frozen_string_literal: true

require "yaml"
load File.expand_path("../.github/scripts/catalog-refresh-pr.rb", __dir__)

# #439: the nightly catalog refresh opens its own pull request; stored logs are no gate, `catalog live` is.
RSpec.describe CatalogRefreshPr do
  def pr(number, ref, same_logs: false)
    { number: number, ref: ref, same_logs: same_logs }
  end

  describe ".decide" do
    it "opens nothing when the stored logs still match the engine" do
      expect(described_class.decide(logs_changed: false, open_prs: [])).to include(action: :none, close: [])
    end

    it "opens a refresh pull request when a log changed and none is open" do
      expect(described_class.decide(logs_changed: true, open_prs: [pr(7, "feature/x")])).to include(action: :create, close: [])
    end

    it "keeps an open nightly refresh pull request that already carries these logs (no second one)" do
      decision = described_class.decide(logs_changed: true, open_prs: [pr(8, "refresh/catalog-nightly-2026-11-17-1", same_logs: true)])

      expect(decision).to include(action: :none, close: [])
      expect(decision[:reason]).to include("#8")
    end

    it "replaces an outdated nightly refresh pull request: one new, the old one closed" do
      decision = described_class.decide(logs_changed: true, open_prs: [pr(8, "refresh/catalog-nightly-2026-11-17-1")])

      expect(decision).to include(action: :create, close: [8])
    end

    it "closes an open nightly refresh pull request once main needs none any more" do
      expect(described_class.decide(logs_changed: false, open_prs: [pr(8, "refresh/catalog-nightly-2026-11-17-1")]))
        .to include(action: :none, close: [8])
    end

    it "leaves a hand-made refresh pull request alone and opens no second one" do
      decision = described_class.decide(logs_changed: true, open_prs: [pr(9, "refresh/catalog-2026-11-17-435")])

      expect(decision).to include(action: :skip, close: [])
      expect(decision[:reason]).to include("#9")
    end
  end

  it "names the nightly branch so that the guard of ci.yml lets its logs through" do
    branch = described_class.branch("2026-11-18", 123)

    expect(branch).to eq("refresh/catalog-nightly-2026-11-18-123")
    expect(branch).to start_with("refresh/catalog-")
  end

  describe "workflows" do
    def workflow(name)
      YAML.safe_load(File.read(File.expand_path("../.github/workflows/#{name}", __dir__)), aliases: true)
    end

    it "replays the stored logs in no gate: full runs the catalog and invariants specs only live" do
      full = workflow("full.yml")
      shard = full["jobs"]["rspec"]["steps"].find { |s| s["name"] == "rspec shard" }["run"]
      live = full["jobs"]["catalog-live"]["steps"].find { |s| s.dig("env", "OE_CATALOG") == "live" }["run"]

      exclude = Regexp.new(shard[/shard\.rb \$\{\{ matrix\.shard \}\} 4 '([^']+)'/, 1])
      expect(%w[spec/oe/fixture_catalog_spec.rb spec/oe/invariants_spec.rb]).to all(match(exclude))
      expect(live).to include("spec/oe/fixture_catalog_spec.rb", "spec/oe/invariants_spec.rb")
    end

    it "runs full nightly and starts the catalog refresh after the nightly run" do
      expect(workflow("full.yml")[true]["schedule"]).not_to be_empty # YAML reads the key `on` as true
      refresh = workflow("catalog-refresh.yml")

      expect(refresh[true]["workflow_run"]).to include("workflows" => ["full"], "types" => ["completed"])
      expect(refresh["jobs"]["pr"]["steps"].map { |s| s["run"].to_s }.join).to include(".github/scripts/catalog-refresh-pr.rb")
    end

    it "keeps the guard: a feature pull request changes no stored log" do
      guard = workflow("ci.yml")["jobs"]["changes"]["steps"].find { |s| s["name"].to_s.start_with?("guard") }

      expect(guard["run"]).to include("spec/fixtures/games/logs/", "refresh/catalog-*", "exit 1")
    end
  end
end
