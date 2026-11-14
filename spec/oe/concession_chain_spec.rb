# frozen_string_literal: true

require_relative "../engine/engine_helper"
require "oe/bot_runner"
require "oe/store"
require "oe/view"

# #289: the owner's live game "hung" after "Witzman executes the 1st Concession" (DSJ parred at 60, home
# token on I50). Through the server it does not: the same human holds the 2nd concession, and the view
# hands him the next founding. (The hang was in the browser: the busy lock of the frame, see
# web/test/concession-browser.test.ts; the states there are recorded from exactly this game.)
RSpec.describe "concession chain over the server (#289)" do
  let(:store) { Oe::Store.new(":memory:") }
  let(:runner) { Oe::BotRunner.new(store) }
  let(:seats) do
    [{ "seat" => 0, "kind" => "human", "name" => "Witzman", "account_id" => "acc0" }] +
      (1..3).map { |i| { "seat" => i, "kind" => "bot", "name" => "Bot #{i + 1}" } }
  end

  # Human moves are the bot's choices (seed 2 reaches the concession round with Witzman holding CON1 and CON2).
  def to_concession_round(id)
    500.times do
      runner.drain(id)
      session = Oe::GameSession.load(store, id)
      game = session.game
      return session if game.round.is_a?(Engine::Round::G18OE::Concession)

      action = Oe::Bot.new(game, rng: Random.new(session.seq)).choose(player_id: game.active_players.first.id)
      session.append(action, actor: "acc0", expected_seq: session.seq)
    end
    raise "no concession round"
  end

  it "after Witzman executes the 1st concession (DSJ at 60) he is offered the 2nd one" do
    id = Oe::GameSession.create(store, seats: seats, seed: 2).id
    session = to_concession_round(id)
    game = session.game
    expect(game.concessions.first(2).map { |c| c.owner.id }).to eq(%w[p0 p0])

    price = game.stock_market.par_prices.find { |p| p.price == 60 }
    session.append({ "type" => "par", "entity" => "p0", "entity_type" => "player", "corporation" => "DSJ",
                     "share_price" => price.id, "user" => "p0" }, actor: "acc0", expected_seq: session.seq)
    expect(runner.drain(id)).to eq(0) # no bot is to act

    session = Oe::GameSession.load(store, id)
    game = session.game
    expect(game.log.last(3).map(&:message)).to eq(["DSJ floats", "DSJ places a token on I50", "Witzman executes the 1st Concession"])
    expect(game.active_players.map(&:id)).to eq(["p0"])
    prompt = Oe::View.render(game, viewer: "p0", seq: session.seq)[:prompt]
    expect(prompt).to include(step: "Concession", viewer_to_act: true)
    expect(prompt[:actions].map { |a| a["type"] }.uniq).to eq(["par"])
    expect(prompt[:actions].map { |a| a["corporation"] }).to include("E", "LNWR")
    expect(store.incidents(id)).to be_empty

    # the owner hung again at the 3rd one after the first fix: the server hands it over just the same
    %w[LNWR GWR].each_with_index do |corp, i|
      session = Oe::GameSession.load(store, id)
      session.append({ "type" => "par", "entity" => "p0", "entity_type" => "player", "corporation" => corp,
                       "share_price" => price.id, "user" => "p0" }, actor: "acc0", expected_seq: session.seq)
      runner.drain(id)
      session = Oe::GameSession.load(store, id)
      expect(session.game.log.map(&:message)).to include("Witzman executes the #{i == 0 ? '2nd' : '3rd'} Concession")
      prompt = Oe::View.render(session.game, viewer: "p0", seq: session.seq)[:prompt]
      expect(prompt).to include(step: "Concession", viewer_to_act: true)
    end
    expect(store.incidents(id)).to be_empty
  end
end
