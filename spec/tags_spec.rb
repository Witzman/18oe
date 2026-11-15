# frozen_string_literal: true

require_relative "support/tags"

# #365: only known tags. A typo (:gameflow) would drop an example from both stages' filters without a trace.
RSpec.describe "spec tags" do
  files = Dir[File.expand_path("**/*_spec.rb", __dir__)]
  # `it "...", :tag do`, `describe X, :tag, key: v do` and `tag: true`, on the line that opens the block.
  opener = /^\s*(?:RSpec\.)?(?:describe|context|it|example|specify|xit|fit)\b(.*)\bdo\s*(?:\|.*\|)?\s*$/

  it "uses only tags listed in spec/support/tags.rb" do
    unknown = []
    files.each do |file|
      File.foreach(file).with_index(1) do |line, number|
        next unless (m = opener.match(line))

        # Drop string literals first, so a ", :word" inside a description is no tag.
        rest = m[1].gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, '""')
        tags = rest.scan(/,\s*:(\w+)(?=\s*(?:,|$))/).flatten + rest.scan(/(\w+):\s*true\b/).flatten
        (tags.map(&:to_sym) - OeSpecTags::KNOWN).each { |t| unknown << "#{File.basename(file)}:#{number} :#{t}" }
      end
    end

    expect(unknown).to eq([])
  end

  it "knows the three stage tags" do
    expect(OeSpecTags::STAGE_TAGS).to eq(%i[game_flow full_game browser])
  end
end
