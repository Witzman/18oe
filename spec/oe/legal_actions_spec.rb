# frozen_string_literal: true

require_relative "../engine/engine_helper"
require_relative "../engine/g_18_oe/helpers"
require "oe/legal_actions"

# Property spec for Oe::LegalActions (#30): plays random games from a start
# state and, at checkpoints, replays the move history on a fresh game and
# applies each sampled legal action to that copy. The engine must accept it
# without a GameError. The enumerator itself must not change the game.
RSpec.describe Oe::LegalActions do
  include G18OESpecHelpers

  # Plays `steps` random moves from `build`. Records, per checkpoint, the move
  # history so far and one action per action class (as hashes) to try on a
  # replayed copy. Stops early at a dead end (active step offers action types
  # but the enumerator finds none).
  Played = Struct.new(:checkpoints, :dead_end, :classes, keyword_init: true)

  def play(build, seed:, steps:, every:)
    rng = Random.new(seed)
    game = build.call
    history = []
    played = Played.new(checkpoints: [], dead_end: nil, classes: Hash.new(0))

    steps.times do |index|
      break if game.finished

      before = game.raw_actions.size
      actions = Oe::LegalActions.new(game, limit: 8, rng: rng).call
      expect(game.raw_actions.size).to eq(before) # read-only

      step = game.round.active_step
      if actions.empty?
        played.dead_end = "#{step.class.name.split('::').last} (#{step.current_entity&.name}): " \
                          "#{step.current_actions.inspect}"
        break
      end

      by_class = actions.group_by(&:class)
      if (index % every).zero?
        sample = by_class.values.map { |group| hash_of(group.sample(random: rng)) }
        played.checkpoints << { history: history.dup, actions: sample }
      end

      action = by_class.values.sample(random: rng).sample(random: rng)
      played.classes["#{step.class.name.split('::').last}/#{action.class.name.split('::').last}"] += 1
      game.process_action(action)
      raise "#{action.class}: #{game.exception.message}" if game.exception

      history << game.raw_actions.last
    end
    played
  end

  # Action#to_h is memoized, so a hash taken before processing would lack the id.
  def hash_of(action)
    action.to_h.dup.tap { action.clear_cache }
  end

  def replay(build, history)
    game = build.call
    history.each do |hash|
      game.process_action(hash)
      raise "replay failed: #{game.exception.message}" if game.exception
    end
    game
  end

  def expect_all_accepted(build, played)
    played.checkpoints.each do |checkpoint|
      checkpoint[:actions].each do |hash|
        game = replay(build, checkpoint[:history])
        game.process_action(hash)
        expect(game.exception).to be_nil, "after #{checkpoint[:history].size} moves, #{hash['type']} " \
                                          "#{hash.slice('entity', 'hex', 'tile', 'corporation', 'price', 'choice')}: " \
                                          "#{game.exception&.message}"
      end
    end
  end

  describe "from the start of a 4-player game" do
    let(:build) { -> { Engine::Game::G18OE::Game.new(%w[A B C D], id: 1, seed: 7) } }

    it "starts with a bid or a pass for the first player" do
      actions = described_class.call(build.call)

      expect(actions.map(&:class).uniq).to contain_exactly(Engine::Action::Bid, Engine::Action::Pass)
      expect(actions.map { |a| a.entity.name }.uniq).to eq(["A"])
    end

    it "is empty once the game is finished" do
      game = build.call
      allow(game).to receive(:finished).and_return(true)

      expect(described_class.call(game)).to eq([])
    end

    it "bounds large action families with limit:" do
      game = build.call

      expect(described_class.new(game, limit: 3).call.size).to be < described_class.new(game).call.size
    end
  end

  describe "scenarios reached by hand" do
    # Mutated starts (helpers set up entities directly), so each checkpoint
    # rebuilds the scenario and replays the recorded moves on top of it.
    def operating_build
      lambda do
        game = new_game(%w[a b c])
        game.players.each_with_index { |_player, index| start_major!(game, %w[LNWR PLM SFAI][index], game.players[index]) }
        game.corporations.select { |c| c.type == :major }.each { |major| fund!(game, major, 700) }
        game.phase.next!
        enter_round!(game, game.operating_round(1))
        game
      end
    end

    def consolidation_build
      lambda do
        game = new_game(%w[a b c])
        allow(game).to receive(:major_phase?).and_return(true)
        game.instance_variable_set(:@turn, 2)
        %w[LNWR PLM SFAI].each_with_index { |id, index| start_regional!(game, id, game.players[index]) }
        start_minor!(game, "B", game.players[0], "SP")
        game.phase.next!
        enter_round!(game, game.new_consolidation_round)
        game
      end
    end

    def stock_build
      lambda do
        game = new_game(%w[a b c])
        game.instance_variable_set(:@turn, 2)
        %w[LNWR PLM].each_with_index { |id, index| start_regional!(game, id, game.players[index]) }
        game.players.each { |player| fund!(game, player) }
        enter_round!(game, game.stock_round)
        game
      end
    end

    it "offers only accepted actions in a consolidation round" do
      played = play(consolidation_build, seed: 4, steps: 60, every: 3)

      expect(played.classes.keys).to include(a_string_matching(%r{Consolidate/Convert}), a_string_matching(%r{MergeOffer/Choose}))
      expect_all_accepted(consolidation_build, played)
    end

    it "offers only accepted actions in a stock round with regionals" do
      played = play(stock_build, seed: 5, steps: 80, every: 4)

      expect(played.classes.keys).to include("BuySellParShares/Choose", "BuySellParShares/Par")
      expect_all_accepted(stock_build, played)
    end

    it "offers only accepted actions in an operating round with majors" do
      played = play(operating_build, seed: 3, steps: 150, every: 6)

      expect(played.classes.keys.map { |k| k.split("/").first }).to include("Track", "Route", "Dividend", "BuyTrain")
      expect_all_accepted(operating_build, played)
    end
  end

  describe "random play" do
    [1, 2].each do |seed|
      it "only offers actions the engine accepts (seed #{seed})" do
        build = -> { Engine::Game::G18OE::Game.new(%w[A B C D], id: 1, seed: seed) }
        played = play(build, seed: seed, steps: 1100, every: 90)

        expect(played.checkpoints.size).to be >= 8
        expect_all_accepted(build, played)
      end
    end

    # Used to be the known engine dead ends (#85 first-round insolvency, #86 token re-placement).
    it "never leaves an active step without an action" do
      build = -> { Engine::Game::G18OE::Game.new(%w[A B C D], id: 1, seed: 1) }
      played = play(build, seed: 1, steps: 3000, every: 10_000)

      expect(played.dead_end).to be_nil
    end
  end
end
