# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/bot_runner"
require "oe/legal_actions"
require "tmpdir"

RSpec.describe Oe::BotRunner do
  let(:store) { Oe::Store.new(":memory:") }
  let(:runner) { described_class.new(store) }

  def seats(*kinds)
    kinds.each_with_index.map do |kind, i|
      seat = { "seat" => i, "kind" => kind.to_s, "name" => "S#{i}" }
      seat["account_id"] = "acc#{i}" if kind == :human
      seat
    end
  end

  def new_game(kinds, seed: 1, on: store)
    Oe::GameSession.create(on, seats: seats(*kinds), seed: seed)
  end

  def reload(id, on: store)
    on.sessions.clear
    Oe::GameSession.load(on, id)
  end

  def log(id, on: store)
    on.action_rows(id)
  end

  def human_move(id, actor: "acc0", on: store)
    session = Oe::GameSession.load(on, id)
    action = Oe::LegalActions.new(session.game, limit: 8, rng: Random.new(session.seq)).call.first
    session.append(action, actor: actor, expected_seq: session.seq)
  end

  def acting(id, on: store)
    Oe::GameSession.load(on, id).game.active_players.map(&:id)
  end

  def without_time(rows)
    rows.map { |r| r["payload"].reject { |k, _| k == "created_at" } }
  end

  it "plays a bots-only game to its regular end from one kick, as bot:<seat> with gapless seq" do
    id = new_game(%i[bot bot bot], seed: 1).id
    expect(runner.kick(id)).to be(true)
    expect(runner.wait_idle(id, timeout: 240)).to be(true)

    session = reload(id)
    expect(session.game.finished).to be(true)
    expect(session.status).to eq("finished")
    rows = log(id)
    expect(rows.map { |r| r["seq"] }).to eq((1..rows.size).to_a)
    expect(rows.map { |r| r["actor"] }.uniq.sort).to eq(%w[bot:0 bot:1 bot:2])
    expect(store.incidents(id)).to eq([])
  end

  it "stops at the human: bots move until a human is on turn, then continue after the human's move" do
    id = new_game(%i[human bot bot], seed: 2).id
    runner.drain(id)
    expect(acting(id)).to eq(["p0"])
    seq_before = store.last_seq(id)

    3.times do
      human_move(id)
      runner.drain(id)
      expect(acting(id)).to eq(["p0"]) unless reload(id).game.finished
    end
    rows = log(id)
    expect(store.last_seq(id)).to be > seq_before + 3
    expect(rows.map { |r| r["actor"] }.uniq.sort).to eq(%w[acc0 bot:1 bot:2])
    expect(without_time(rows).size).to eq(rows.size)
    expect { reload(id) }.not_to raise_error # the whole log replays
  end

  it "plays asynchronously after a game was created (kick does not wait)" do
    id = new_game(%i[human bot bot], seed: 2).id
    runner.kick(id)
    expect(runner.wait_idle(id, timeout: 60)).to be(true)
    expect(acting(id)).to eq(["p0"])
  end

  describe "robustness" do
    # A bot that always fails; it still enumerates legal actions (for the fallback).
    let(:broken_class) do
      Class.new(Oe::Bot) do
        def choose(player_id: nil) = raise("boom")
      end
    end

    # A bot that proposes an action the engine rejects (a pass for someone who is not on turn).
    let(:rejected_class) do
      Class.new(Oe::Bot) do
        def choose(player_id: nil)
          idle = @game.players.find { |p| @game.active_players.none? { |a| a.id == p.id } }
          Engine::Action::Pass.new(idle)
        end
      end
    end

    it "falls back to a random legal action when the bot raises, and records incidents" do
      broken = described_class.new(store, bot_factory: ->(game, rng) { broken_class.new(game, rng: rng) })
      id = new_game(%i[bot bot bot], seed: 1).id
      expect(broken.drain(id, max: 30)).to eq(30)

      expect(store.last_seq(id)).to eq(30)
      kinds = store.incidents(id).map { |i| i["kind"] }
      expect(kinds).to include("bot_error", "fallback")
      expect(store.incidents(id).first["message"]).to include("boom")
      expect { reload(id) }.not_to raise_error
    end

    it "falls back when the engine rejects the bot's action, and leaves no trace of it in the log" do
      bad = described_class.new(store, bot_factory: ->(game, rng) { rejected_class.new(game, rng: rng) })
      id = new_game(%i[bot bot bot], seed: 1).id
      expect(bad.drain(id, max: 12)).to eq(12)

      expect(store.last_seq(id)).to eq(12)
      expect(store.incidents(id).map { |i| i["kind"] }).to include("bot_rejected", "fallback")
      expect(log(id).map { |r| r["action_type"] }).not_to be_empty
      expect { reload(id) }.not_to raise_error
    end

    it "gives up with a stuck incident (and does not loop) when nothing is accepted" do
      allow_any_instance_of(Oe::GameSession).to receive(:append).and_raise(Oe::GameSession::Rejected, "nope")
      id = new_game(%i[bot bot bot], seed: 1).id
      expect(runner.drain(id, max: 5)).to eq(0)
      expect(store.incidents(id).map { |i| i["kind"] }).to include("stuck")
    end
  end

  it "resumes a chain cut by a restart (new runner, resume_all)" do
    id = new_game(%i[human bot bot], seed: 2).id
    runner.drain(id)
    human_move(id)
    expect(runner.drain(id, max: 1)).to eq(1) # the chain is cut after the first bot move
    cut = store.last_seq(id)
    expect(acting(id)).not_to eq(["p0"])

    fresh = described_class.new(store) # a new process: no memory
    store.sessions.clear
    fresh.resume_all
    expect(fresh.wait_idle(id, timeout: 60)).to be(true)
    expect(store.last_seq(id)).to be > cut
    expect(acting(id)).to eq(["p0"])
  end

  it "ignores finished and bot-less games on resume" do
    human_only = new_game(%i[human human], seed: 1).id
    fresh = described_class.new(store)
    fresh.resume_all
    expect(fresh.wait_idle(human_only, timeout: 5)).to be(true)
    expect(store.last_seq(human_only)).to eq(0)
  end

  it "never produces duplicate moves when two runners drain the same game at once" do
    id = new_game(%i[bot bot bot], seed: 4).id
    runners = Array.new(2) { described_class.new(store) }
    threads = runners.map { |r| Thread.new { r.drain(id, max: 60) } }
    threads.each(&:join)

    rows = log(id)
    expect(rows.map { |r| r["seq"] }).to eq((1..rows.size).to_a)
    expect(rows.size).to be_between(60, 120)
    expect(rows.map { |r| r["payload"]["id"] }).to eq((1..rows.size).to_a)
    expect { reload(id) }.not_to raise_error
  end

  it "coalesces repeated kicks into one worker" do
    id = new_game(%i[human bot bot], seed: 2).id
    results = Array.new(5) { runner.kick(id) }
    expect(results.first).to be(true)
    expect(runner.wait_idle(id, timeout: 60)).to be(true)
    rows = log(id)
    expect(rows.map { |r| r["seq"] }).to eq((1..rows.size).to_a)
    expect(acting(id)).to eq(["p0"])
  end

  it "plays the same moves for the same game seed (rng from seed + seq)" do
    other = Oe::Store.new(":memory:")
    a = new_game(%i[bot bot bot], seed: 5).id
    b = new_game(%i[bot bot bot], seed: 5, on: other).id
    runner.drain(a, max: 80)
    described_class.new(other).drain(b, max: 80)
    expect(without_time(log(a))).to eq(without_time(log(b, on: other)))
    expect(log(a).size).to eq(80)
  end

  it "reseeding the bot makes a choice depend only on the seed" do
    game = Engine::Game::G18OE::Game.new(%w[p0 p1 p2], id: 1, seed: 1)
    bot = Oe::Bot.new(game, rng: Random.new(0))
    pid = game.active_players.first.id
    picks = [11, 12, 11].map do |seed|
      bot.reseed(seed)
      bot.choose(player_id: pid).to_h.reject { |k, _| k == "created_at" }
    end
    expect(picks[0]).to eq(picks[2])
  end

  describe "store migration 2" do
    it "upgrades an existing version-1 database and keeps its games" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "old.sqlite3")
        old = SQLite3::Database.new(path)
        old.execute_batch(Oe::Store::MIGRATIONS.fetch(1))
        old.execute("PRAGMA user_version = 1")
        old.execute("INSERT INTO games (created_at, status, seats, seed, engine_rev) VALUES ('t', 'active', '[]', 9, 'x')")
        old.close

        upgraded = Oe::Store.new(path)
        expect(upgraded.schema_version).to eq(Oe::Store::SCHEMA_VERSION)
        expect(upgraded.game(1)["seed"]).to eq(9)
        upgraded.add_incident(game_id: 1, seq: 0, kind: "stuck", message: "m")
        expect(upgraded.incidents(1).first).to include("kind" => "stuck", "message" => "m")
        upgraded.close
      end
    end
  end
end
