# frozen_string_literal: true

# #566 (#563 Task 3): the engine switch discards games, never accounts.
require "spec_helper"
require "tmpdir"
require "sqlite3"

RSpec.describe Oe::Store do
  it "migration 5 drops games, actions and incidents of an old-format database and keeps accounts" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "old.sqlite3")
      db = SQLite3::Database.new(path)
      (1..4).each { |v| db.execute_batch(described_class::MIGRATIONS.fetch(v)) }
      db.execute("PRAGMA user_version = 4")
      db.execute("INSERT INTO accounts (id, name, email, password_hash, created_at) VALUES ('a1','Alice','alice@example.test','x','t')")
      db.execute("INSERT INTO games (created_at, status, seats, seed, engine_rev) VALUES ('t','active','[]',1,'old')")
      db.execute("INSERT INTO actions (game_id, seq, actor, action_type, payload, created_at) VALUES (1,1,'a1','bid','{}','t')")
      db.execute("INSERT INTO incidents (game_id, seq, kind, message, created_at) VALUES (1,1,'stuck','m','t')")
      db.close

      store = described_class.new(path)
      expect(store.schema_version).to eq(described_class::SCHEMA_VERSION)
      expect(store.games).to be_empty
      expect(store.action_rows(1)).to be_empty
      expect(store.account("a1")&.fetch("name")).to eq("Alice")
      store.close
    end
  end

  it "does not discard anything on a database already at the current version" do
    store = described_class.new(":memory:")
    store.create_game(seats: [], seed: 1, engine_rev: "x")
    store.send(:migrate!)
    expect(store.games.size).to eq(1)
  end
end
