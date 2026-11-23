# frozen_string_literal: true

load File.expand_path("../.github/scripts/engine-upstream-watch.rb", __dir__)

# #579: the nightly watch keeps exactly one open issue while upstream moved on the paths we take over.
RSpec.describe EngineUpstreamWatch do
  def issue(number, title) = { number: number, title: title }

  describe ".decide" do
    it "does nothing when nothing changed and no issue is open" do
      expect(described_class.decide(changed: false, open_issues: [issue(3, "other")])).to eq(action: :none, number: nil)
    end

    it "creates the issue on the first change" do
      expect(described_class.decide(changed: true, open_issues: [])).to eq(action: :create, number: nil)
    end

    it "updates the open issue instead of opening a second one" do
      open = [issue(3, "other"), issue(9, "#{described_class::TITLE}: 2 Commit(s)")]
      expect(described_class.decide(changed: true, open_issues: open)).to eq(action: :update, number: 9)
    end

    it "closes the issue once the pin has caught up" do
      open = [issue(9, "#{described_class::TITLE}: 2 Commit(s)")]
      expect(described_class.decide(changed: false, open_issues: open)).to eq(action: :close, number: 9)
    end
  end

  it "lists the commits and the way to move the pin" do
    body = described_class.issue_body(pin: "a" * 40, head: "b" * 40, log: ["1234567 Fix tile lay (#1)"])
    expect(body).to include("- 1234567 Fix tile lay (#1)", "bin/engine-sync bbbbbbbbb")
  end

  describe ".relevant" do
    it "keeps commits touching core or 18OE, drops commits touching only other titles" do
      out = <<~LOG
        @aaa1111 foreign only
        lib/engine/game/g_1830/game.rb
        lib/engine/game/g_1830/step/x.rb

        @bbb2222 18oe
        lib/engine/game/g_18_oe/game.rb

        @ccc3333 core and foreign
        lib/engine/game/g_1889/game.rb
        lib/engine/step/base.rb

        @ddd4444 other 18oe-like title
        lib/engine/game/g_18_oe_x/game.rb
      LOG
      expect(described_class.relevant(out)).to eq(["bbb2222 18oe", "ccc3333 core and foreign"])
    end
  end
end
