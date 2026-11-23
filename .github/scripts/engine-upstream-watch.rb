#!/usr/bin/env ruby
# frozen_string_literal: true

# Nightly upstream watch (#579, #563 Task 11). Runs in engine-upstream-watch.yml in a checkout of this repo.
# Compares engine/PIN with tobymao/18xx master on the paths this repo takes over (core + the 18OE titles). If they
# differ it opens ONE issue "Upstream-Aenderung an 18OE/Kern: ..." with the commit list, or updates the open one;
# if they do not, it closes an open one. Read-only on upstream (a clone, never a PR/issue there, CLAUDE.md rule 32).
# Env: GITHUB_TOKEN, GITHUB_REPOSITORY. Moving the pin: `bin/engine-sync <sha>` in a PR (notes/traps/engine-sync.md).
require "json"
require "net/http"
require "tmpdir"
require "uri"

module EngineUpstreamWatch
  TITLE = "Upstream-Aenderung an 18OE/Kern"
  UPSTREAM_URL = "https://github.com/tobymao/18xx.git"
  # Paths of upstream that can end up in lib/engine; foreign titles are filtered per file (as engine/sync.rb does:
  # git pathspec excludes cannot be re-included).
  PATHSPEC = %w[lib/engine.rb lib/engine].freeze
  KEEP_TITLES = %w[g_18_oe g_18_oe_uk_fr].freeze

  module_function

  # log: lines "sha subject" (oldest first or newest first, kept as given).
  def issue_body(pin:, head:, log:)
    commits = log.map { |l| "- #{l}" }.join("\n")
    <<~TEXT
      Upstream master (`#{head[0, 9]}`) hat Aenderungen an Kern oder 18OE gegenueber `engine/PIN` (`#{pin[0, 9]}`):

      #{commits}

      Pin anheben: Branch, `bin/engine-sync #{head[0, 9]}`, danach `spec/engine/upstream` und `spec/oe` gezielt gruen
      (Falle `engine-sync`). Chris' Loesung ist der Zielzustand (Regel 32); Konflikte mit `engine/patches/` im PR nennen.
      Dieses Issue wird vom Workflow `engine-upstream-watch` gepflegt und geschlossen, sobald der Pin nachzieht.
    TEXT
  end

  # open_issues: [{ number:, title: }]. -> { action: :none | :create | :update | :close, number: }
  def decide(changed:, open_issues:)
    mine = open_issues.find { |i| i[:title].start_with?(TITLE) }
    if changed
      mine ? { action: :update, number: mine[:number] } : { action: :create, number: nil }
    else
      mine ? { action: :close, number: mine[:number] } : { action: :none, number: nil }
    end
  end

  def foreign?(path)
    m = path.match(%r{\Alib/engine/game/(g_[^/]+?)(?:\.rb)?(?:/|\z)})
    m && !KEEP_TITLES.include?(m[1])
  end

  # git log --format=@%h %s --name-only output -> ["sha subject", ...] of commits touching a file we take over.
  def relevant(log_output)
    log_output.split(/^@/).reject(&:empty?).filter_map do |chunk|
      head, *files = chunk.lines.map(&:strip).reject(&:empty?)
      head if files.any? { |f| !foreign?(f) }
    end
  end

  def sh(*cmd, chdir: nil)
    out = IO.popen(cmd, chdir: chdir || ".", err: %i[child out], &:read)
    raise "failed: #{cmd.join(' ')}\n#{out}" unless $?.success?

    out
  end

  def api(method, path, body = nil)
    uri = URI("https://api.github.com#{path}")
    req = Net::HTTP.const_get(method.capitalize).new(uri)
    req["Authorization"] = "Bearer #{ENV.fetch('GITHUB_TOKEN')}"
    req["Accept"] = "application/vnd.github+json"
    req.body = JSON.generate(body) if body
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    raise "#{method} #{path}: HTTP #{res.code} #{res.body.to_s[0, 400]}" unless res.code.start_with?("2")

    res.body.to_s.empty? ? nil : JSON.parse(res.body)
  end

  # Returns [head_sha, log lines] of upstream commits touching our paths since the pin (blobless clone, no checkout).
  def upstream_changes(pin, dir)
    sh("git", "clone", "--quiet", "--filter=blob:none", "--no-checkout", "--single-branch", "--branch", "master",
       UPSTREAM_URL, dir)
    head = sh("git", "rev-parse", "HEAD", chdir: dir).strip
    log = relevant(sh("git", "log", "--format=@%h %s", "--name-only", "#{pin}..#{head}", "--", *PATHSPEC, chdir: dir))
    [head, log]
  end

  def run
    repo = ENV.fetch("GITHUB_REPOSITORY")
    pin = File.read("engine/PIN").strip
    head, log = Dir.mktmpdir { |d| upstream_changes(pin, File.join(d, "up")) }
    open_issues = api("GET", "/repos/#{repo}/issues?state=open&per_page=100")
                  .reject { |i| i["pull_request"] }.map { |i| { number: i["number"], title: i["title"] } }
    decision = decide(changed: !log.empty?, open_issues: open_issues)
    puts "::notice::upstream watch: #{decision[:action]} (pin #{pin[0, 9]}, master #{head[0, 9]}, #{log.size} commits)"
    title = "#{TITLE}: #{log.size} Commit(s) seit #{pin[0, 9]}"
    body = issue_body(pin: pin, head: head, log: log)
    case decision[:action]
    when :create then api("POST", "/repos/#{repo}/issues", { title: title, body: body })
    when :update then api("PATCH", "/repos/#{repo}/issues/#{decision[:number]}", { title: title, body: body })
    when :close
      api("PATCH", "/repos/#{repo}/issues/#{decision[:number]}", { state: "closed" })
    end
    return unless ENV["GITHUB_STEP_SUMMARY"]

    File.write(ENV["GITHUB_STEP_SUMMARY"], "### upstream watch\n\n#{decision[:action]}: #{log.size} commit(s)\n", mode: "a")
  end
end

EngineUpstreamWatch.run if $PROGRAM_NAME == __FILE__
