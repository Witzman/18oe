#!/usr/bin/env ruby
# frozen_string_literal: true

# Nightly catalog refresh pull request (#439). Runs in catalog-refresh.yml, job `pr`, in a checkout of the commit
# the logs were rebuilt with, the rebuilt spec/fixtures/games/ already in place. Opens at most one refresh PR:
#   - no stored log (*.jsonl) changed       -> nothing; an open nightly refresh PR is closed (no longer needed)
#   - a hand-made refresh PR is open        -> nothing (notice), no second refresh PR
#   - an open nightly PR has the same logs  -> nothing, it stays
#   - otherwise                             -> branch refresh/catalog-nightly-<date>-<run>, PR, ci.yml dispatched for
#                                              it (a PR opened with GITHUB_TOKEN starts no pull_request workflow);
#                                              an older nightly PR is closed and its branch deleted
# The guard of ci.yml (job `changes`) lets logs through only on refresh/catalog-*: the branch name matters.
# Env: GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_SERVER_URL. Merging the PR stays with the session
# that reads the nightly run (`bin/pr merge <n>` in the workshop), see README "Fixture catalog".
require "json"
require "net/http"
require "uri"

module CatalogRefreshPr
  PREFIX = "refresh/catalog-"
  NIGHTLY = "refresh/catalog-nightly-"
  LOGS = "spec/fixtures/games/logs"

  module_function

  # open_prs: [{ number:, ref:, same_logs: }] (same_logs: that PR's *.jsonl equal the rebuilt ones).
  # Returns { action: :none | :skip | :create, close: [PR numbers], reason: text }.
  def decide(logs_changed:, open_prs:)
    refresh = open_prs.select { |p| p[:ref].start_with?(PREFIX) }
    nightly = refresh.select { |p| p[:ref].start_with?(NIGHTLY) }
    manual = refresh - nightly
    unless logs_changed
      return { action: :none, close: nightly.map { |p| p[:number] }, reason: "the stored logs match the engine" }
    end
    unless manual.empty?
      return { action: :skip, close: [], reason: "hand-made refresh PR #{manual.map { |p| "##{p[:number]}" }.join(', ')} is open" }
    end
    if (same = nightly.find { |p| p[:same_logs] })
      return { action: :none, close: (nightly - [same]).map { |p| p[:number] }, reason: "open refresh PR ##{same[:number]} already has these logs" }
    end

    { action: :create, close: nightly.map { |p| p[:number] }, reason: "stored logs changed" }
  end

  def branch(date, run_id)
    "#{NIGHTLY}#{date}-#{run_id}"
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

  def sh(*cmd)
    system(*cmd) || raise("failed: #{cmd.join(' ')}")
  end

  def changed_logs
    `git status --porcelain -- #{LOGS}`.lines.map { |l| l[3..].strip }.grep(/\.jsonl\z/)
  end

  def run
    repo = ENV.fetch("GITHUB_REPOSITORY")
    run_url = "#{ENV.fetch('GITHUB_SERVER_URL', 'https://github.com')}/#{repo}/actions/runs/#{ENV.fetch('GITHUB_RUN_ID')}"
    sha = `git rev-parse HEAD`.strip
    changed = changed_logs
    sh("git", "config", "user.name", "github-actions[bot]")
    sh("git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
    new_branch = branch(Time.now.utc.strftime("%Y-%m-%d"), ENV.fetch("GITHUB_RUN_ID"))
    unless changed.empty?
      sh("git", "checkout", "-q", "-b", new_branch)
      sh("git", "add", "--", LOGS)
      sh("git", "commit", "-q", "-m", "Katalog-Refresh (nachts) mit engine #{sha[0, 7]}")
    end

    open_prs = api("GET", "/repos/#{repo}/pulls?state=open&per_page=100").map do |p|
      ref = p["head"]["ref"]
      same = false
      if !changed.empty? && ref.start_with?(NIGHTLY)
        sh("git", "fetch", "-q", "--depth=1", "origin", "+refs/heads/#{ref}:refs/remotes/origin/#{ref}")
        same = system("git", "diff", "--quiet", "origin/#{ref}", "HEAD", "--", "#{LOGS}/*.jsonl")
      end
      { number: p["number"], ref: ref, same_logs: same }
    end
    decision = decide(logs_changed: !changed.empty?, open_prs: open_prs)
    puts "::notice::catalog refresh: #{decision[:action]} (#{decision[:reason]}); changed logs: #{changed.join(', ')}"
    summary = ["### refresh pull request", "", "#{decision[:action]}: #{decision[:reason]}"]

    if decision[:action] == :create
      sh("git", "push", "-q", "origin", "HEAD:refs/heads/#{new_branch}")
      body = <<~TEXT
        Automatisch erzeugt vom Workflow `catalog-refresh` (#{run_url}) nach dem Nachtlauf von `full` (workshop #439).
        Neu gebaut mit der Engine von #{sha}: #{changed.join(', ')}.
        Die Diffs je Spiel (erste abweichende Aktion, verschobene Eintraege) stehen in der Step-Summary des Laufs.

        Nur gespeicherte Katalog-Logs; Gate fuer den Katalog ist `catalog live` in `full`. Die fast-Pruefung wurde per
        `workflow_dispatch` gestartet. Merge: `bin/pr merge <n>` (ggf. `--update`), wenn fast gruen ist.
      TEXT
      begin
        created = api("POST", "/repos/#{repo}/pulls",
                      { title: "Katalog-Refresh nachts (engine #{sha[0, 7]})", head: new_branch, base: "main", body: body })
      rescue RuntimeError => e
        puts "::error::branch #{new_branch} pushed, but the pull request could not be opened: #{e.message}. " \
             "If HTTP 403: repository Settings > Actions > General > Workflow permissions > " \
             "'Allow GitHub Actions to create and approve pull requests' must be on (owner)."
        raise
      end
      api("POST", "/repos/#{repo}/actions/workflows/ci.yml/dispatches", { ref: new_branch })
      summary.push "", "opened ##{created['number']} (#{new_branch}), ci.yml dispatched"
      note = "Ersetzt durch ##{created['number']} (neuerer Nachtlauf, #{run_url})."
    end
    note ||= "Nicht mehr noetig: #{decision[:reason]} (#{run_url})."
    decision[:close].each do |n|
      old = open_prs.find { |p| p[:number] == n }
      api("POST", "/repos/#{repo}/issues/#{n}/comments", { body: note })
      api("PATCH", "/repos/#{repo}/pulls/#{n}", { state: "closed" })
      api("DELETE", "/repos/#{repo}/git/refs/heads/#{old[:ref]}")
      summary << "closed ##{n}"
    end
    File.write(ENV["GITHUB_STEP_SUMMARY"], "#{summary.join("\n")}\n", mode: "a") if ENV["GITHUB_STEP_SUMMARY"]
  end
end

CatalogRefreshPr.run if $PROGRAM_NAME == __FILE__
