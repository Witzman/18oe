# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/game_session"
require "oe/legal_actions"
require "tmpdir"

RSpec.describe Oe::GameSession do
  let(:seats) do
    (0..3).map { |i| { "seat" => i, "kind" => "human", "account_id" => "acc#{i}", "name" => ("A".."D").to_a[i] } }
  end
  let(:store) { Oe::Store.new(":memory:") }

  # Cash, holdings and position of everything that matters for "same state".
  def fingerprint(game)
    {
      round: game.round.class.name,
      turn: game.turn,
      players: game.players.map { |p| [p.id, p.cash, p.shares.map(&:id).sort, p.companies.map(&:id).sort] },
      corporations: game.corporations.map { |c| [c.id, c.cash, c.trains.map(&:id), c.tokens.count { |t| t.used }] },
      raw: game.raw_actions,
      finished: game.finished,
    }
  end

  def play(session, count, seed: 1)
    rng = Random.new(seed)
    played = 0
    count.times do
      actions = Oe::LegalActions.new(session.game, limit: 8, rng: rng).call
      break if actions.empty? || session.game.finished

      action = actions.group_by(&:class).values.sample(random: rng).sample(random: rng)
      session.append(action, actor: "test")
      played += 1
    end
    played
  end

  describe Oe::Store do
    it "creates the schema and records its version" do
      expect(store.schema_version).to eq(Oe::Store::SCHEMA_VERSION)
    end

    it "does not migrate twice" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "x.sqlite3")
        Oe::Store.new(path).close
        reopened = Oe::Store.new(path)
        expect(reopened.schema_version).to eq(Oe::Store::SCHEMA_VERSION)
        reopened.close
      end
    end

    it "uses WAL for file databases" do
      Dir.mktmpdir do |dir|
        s = Oe::Store.new(File.join(dir, "x.sqlite3"))
        mode = s.instance_variable_get(:@db).get_first_value("PRAGMA journal_mode")
        expect(mode).to eq("wal")
        s.close
      end
    end
  end

  it "creates a game with seed and engine revision" do
    session = described_class.create(store, seats: seats, seed: 7)
    row = store.game(session.id)
    expect(row["seed"]).to eq(7)
    expect(row["engine_rev"]).to match(/\A06b3f0b37\+\h{12}\z/)
    expect(row["status"]).to eq("active")
    expect(row["seats"].size).to eq(4)
  end

  it "raises NotFound for an unknown game" do
    expect { described_class.load(store, 999) }.to raise_error(described_class::NotFound)
  end

  it "round-trips: stored log, replayed, gives the identical state" do
    session = described_class.create(store, seats: seats, seed: 3)
    expect(play(session, 300)).to be > 100
    live = fingerprint(session.game)

    store.sessions.clear # force a replay from the log
    reloaded = described_class.load(store, session.id)
    expect(reloaded.seq).to eq(session.seq)
    expect(reloaded.game).not_to equal(session.game)
    expect(fingerprint(reloaded.game)).to eq(live)
  end

  it "stores gapless seq 1..n equal to the engine action ids" do
    session = described_class.create(store, seats: seats, seed: 3)
    n = play(session, 40)
    ids = store.action_payloads(session.id).map { |p| p["id"] }
    expect(ids).to eq((1..n).to_a)
    expect(store.last_seq(session.id)).to eq(n)
  end

  it "loses nothing when the process restarts (new Store on the same file)" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "g.sqlite3")
      first = Oe::Store.new(path)
      session = described_class.create(first, seats: seats, seed: 5)
      play(session, 150)
      live = fingerprint(session.game)
      first.close

      second = Oe::Store.new(path)
      reloaded = described_class.load(second, session.id)
      expect(fingerprint(reloaded.game)).to eq(live)
      second.close
    end
  end

  it "uses the cache when seq matches" do
    session = described_class.create(store, seats: seats, seed: 3)
    play(session, 20)
    expect(described_class.load(store, session.id).game).to equal(session.game)
  end

  it "notices a write by another process (second Store) and replays instead of using a stale cache" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "g.sqlite3")
      mine = Oe::Store.new(path)
      theirs = Oe::Store.new(path)
      session = described_class.create(mine, seats: seats, seed: 3)
      play(session, 10)
      other = described_class.load(theirs, session.id)
      play(other, 5) # advances the log to 15 behind my back

      expect(mine.sessions[session.id][:seq]).to eq(10) # my cache is stale

      # a decision based on seq 10 is a conflict
      next_hash = Oe::LegalActions.new(other.game, limit: 4, rng: Random.new(4)).call.first.to_h
      expect { session.append(next_hash, actor: "me", expected_seq: 10) }
        .to raise_error(described_class::Conflict)

      # an action that is valid for the real state goes through: append reloads first
      expect(session.append(next_hash, actor: "me")).to eq(16)
      expect(mine.last_seq(session.id)).to eq(16)
      expect(fingerprint(described_class.load(theirs, session.id).game))
        .to eq(fingerprint(described_class.load(mine, session.id).game))
      mine.close
      theirs.close
    end
  end

  describe "#append" do
    let(:session) { described_class.create(store, seats: seats, seed: 3) }

    it "leaves the log untouched when the engine rejects an action" do
      play(session, 10)
      before = store.action_payloads(session.id)
      bogus = { "type" => "bid", "entity" => "nobody", "entity_type" => "player", "price" => 1, "company" => "x" }

      expect { session.append(bogus, actor: "test") }.to raise_error(described_class::Rejected)
      expect(store.action_payloads(session.id)).to eq(before)
      expect(store.last_seq(session.id)).to eq(10)
    end

    it "stays usable after a rejection (cache dropped, replayed from log)" do
      play(session, 10)
      bogus = { "type" => "bid", "entity" => "nobody", "entity_type" => "player", "price" => 1, "company" => "x" }
      begin
        session.append(bogus, actor: "test")
      rescue described_class::Rejected
        nil
      end
      fresh = described_class.load(store, session.id)
      expect(play(fresh, 5)).to eq(5)
      expect(store.last_seq(session.id)).to eq(15)
    end

    it "rejects undo and redo" do
      play(session, 3)
      %w[undo redo].each do |type|
        expect { session.append({ "type" => type, "entity" => "A", "entity_type" => "player" }, actor: "t") }
          .to raise_error(described_class::Rejected)
      end
      expect(store.last_seq(session.id)).to eq(3)
    end

    it "gives a conflict when expected_seq is stale; the first writer wins" do
      play(session, 5)
      a = described_class.load(store, session.id)
      b = described_class.load(store, session.id)
      rng = Random.new(9)
      action = ->(s) { Oe::LegalActions.new(s.game, limit: 4, rng: rng).call.first }

      expect(a.append(action.call(a), actor: "a", expected_seq: 5)).to eq(6)
      expect { b.append(action.call(b), actor: "b", expected_seq: 5) }.to raise_error(described_class::Conflict)
      expect(store.last_seq(session.id)).to eq(6)
    end

    it "serialises concurrent appends from threads: exactly one wins per seq" do
      play(session, 5)
      sessions = Array.new(4) { described_class.load(store, session.id) }
      rng = Random.new(2)
      pending = sessions.map { |s| Oe::LegalActions.new(s.game, limit: 4, rng: rng).call.first.to_h }
      results = sessions.zip(pending).map do |s, hash|
        Thread.new do
          s.append(hash, actor: "t", expected_seq: 5)
          :ok
        rescue described_class::Conflict
          :conflict
        end
      end.map(&:value)

      expect(results.count(:ok)).to eq(1)
      expect(results.count(:conflict)).to eq(3)
      expect(store.last_seq(session.id)).to eq(6)
    end

    it "refuses actions on a finished game" do
      store.set_status(session.id, "finished")
      session.game.instance_variable_set(:@finished, true)
      expect { session.append({ "type" => "pass", "entity" => "p0", "entity_type" => "player" }, actor: "t") }
        .to raise_error(described_class::Rejected, /finished/)
    end
  end
end
