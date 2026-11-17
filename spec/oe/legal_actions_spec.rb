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

  # Not :game_flow (#365): the start state is built by code (scenario helpers), no seed game
  # and no recorded log is played; the random moves run from that state with a fixed rng.
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

  describe "random play", :game_flow do
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

  # #309: the engine's rotation check ignores TRACK_RESTRICTION; the step
  # rejects such a lay only when it is processed. #315: the step checks it
  # after laying the tile, so the enumerator must check it on the map as it
  # would look after the lay, or every upgrade is refused.
  describe "#lay_tile_options and the track restriction" do
    # Phase 3 (yellow and green), LNWR operating with track around London.
    def track_build
      game = new_game(%w[a b c])
      game.players.each_with_index { |_player, index| start_major!(game, %w[LNWR PLM SFAI][index], game.players[index]) }
      game.corporations.select { |c| c.type == :major }.each { |major| fund!(game, major, 700) }
      game.phase.next!
      enter_round!(game, game.operating_round(1))
      game
    end

    def offered(game)
      step = game.round.active_step
      described_class.new(game).lay_tile_options(step, step.current_entity).flat_map do |hex, tiles|
        tiles.flat_map { |tile, rotations| rotations.map { |r| [hex.id, tile.name, r] } }
      end
    end

    # Every lay the engine's rotation check allows, before the track restriction.
    def candidates(game)
      step = game.round.active_step
      entity = step.current_entity
      game.hexes.select { |hex| step.available_hex(entity, hex) }.flat_map do |hex|
        step.upgradeable_tiles(entity, hex).flat_map do |tile|
          rotations = tile.legal_rotations
          tile.rotate!(0)
          rotations.map { |r| [hex.id, tile.name, r] }
        end
      end
    end

    def accepted?(hex_id, tile_name, rotation)
      game = track_build
      entity = game.round.active_step.current_entity
      tile = game.tiles.find { |t| t.name == tile_name }
      game.process_action(Engine::Action::LayTile.new(entity, tile: tile, hex: game.hex_by_id(hex_id), rotation: rotation))
      game.exception.nil?
    end

    it "offers exactly the lays the engine accepts, upgrades of yellow tiles included" do
      game = track_build
      all = candidates(game)
      expect(all.map { |hex, _, _| game.hex_by_id(hex).tile.color }.uniq).to include(:yellow, :white)

      accepted = all.select { |lay| accepted?(*lay) }
      expect(accepted).to include(["J27", "205", 1]) # green upgrade of the home city
      expect(accepted).to include(["I20", "57", 4]) # white hex with a preprinted stub (Dublin)
      expect(offered(game)).to match_array(accepted)

      # the same without the shortcut: every upgrade through the trial lay
      allow_any_instance_of(described_class).to receive(:semi_restrictive_verdict).and_return(nil)
      expect(offered(track_build)).to match_array(accepted)
    end

    it "leaves out rotations the engine's check refuses" do
      game = track_build
      step = game.round.active_step
      allow_any_instance_of(described_class).to receive(:semi_restrictive_verdict).and_return(nil)
      allow(step).to receive(:check_track_restrictions!).and_wrap_original do |original, entity, old_tile, new_tile|
        if new_tile.hex&.id == "J27" && new_tile.name == "205" && new_tile.rotation == 1
          raise Engine::GameError, "Must use new track or change city value"
        end

        original.call(entity, old_tile, new_tile)
      end

      lays = offered(game)
      expect(lays).not_to include(["J27", "205", 1])
      expect(lays).to include(["J27", "205", 4])
    end

    it "leaves the map, the tokens and the graph as they were" do
      game = track_build
      entity = game.round.active_step.current_entity
      snapshot = lambda do
        [game.hexes.map { |hex| [hex.id, hex.tile.object_id, hex.tile.hex&.id, hex.paths.values.flatten.size] },
         game.hexes.flat_map { |hex| hex.tile.cities.map { |city| city.tokens.map { |t| t&.corporation&.id } } },
         game.graph_for_entity(entity).connected_paths(entity).keys.map(&:object_id).sort,
         # route info survives Graph#clear once a train may be bought; a trial map must not set it
         game.graph_for_entity(entity).instance_variable_get(:@routes).transform_values(&:dup),
         # (not rotation: Step#upgradeable_tiles leaves tiles it filters out rotated, engine behaviour)
         game.tiles.map { |tile| [tile.object_id, tile.hex&.id] }]
      end
      before = snapshot.call
      offered(game)
      expect(snapshot.call).to eq(before)
    end
  end
end

# #296: pricing a tile while enumerating must not write the zone discount line
# into the real game log.
RSpec.describe Oe::LegalActions, "#lay_tile_options log" do
  include G18OESpecHelpers

  it "leaves the game log unchanged" do
    game = new_game
    corp = game.corporation_by_id("CHN")
    hex = game.hex_by_id("X23")
    step = Object.new
    step.define_singleton_method(:available_hex) { |_e, h| h.id == "X23" }
    step.define_singleton_method(:upgradeable_tiles) { |_e, _h| [] }

    # sanity: the engine does log the discount when pricing directly
    probe = game.log.size
    game.upgrade_cost(hex.tile, hex, corp, corp)
    expect(game.log.size).to be > probe
    game.log.slice!(probe..)

    before = game.log.map(&:message)
    described_class.new(game).lay_tile_options(step, corp)

    expect(game.log.map(&:message)).to eq(before)
  end
end

# #315/#319: the path search runs on every prompt and bot move; unbounded, one
# search in a phase-8 network took 47 s. It is bounded by a visit count.
RSpec.describe Oe::LegalActions::RoutePicker do
  include G18OESpecHelpers

  it "bounds the path search" do
    game = new_game
    corp = game.corporation_by_id("LNWR")
    allow_any_instance_of(Oe::RouteSearch).to receive(:path) do |_router, _trains, _corp, **opts|
      expect(opts[:walk_limit]).to eq(described_class::WALK_LIMIT)
      expect(opts).not_to have_key(:path_timeout)
      [{}]
    end
    expect(described_class.new(game, corp).call).to eq([])
    expect(described_class::WALK_LIMIT).to be_between(1000, 20_000)
  end
end

# #319: walk_limit bounds the number of visits deterministically (no wall clock).
RSpec.describe Oe::RouteSearch do
  include G18OESpecHelpers

  def search(walk_limit)
    game = new_game
    corp = start_major!(game, "LNWR", game.players[0])
    game.phase.next!
    game.buy_train(corp, game.depot.upcoming.first, :free)
    router = described_class.new(game)
    routes, cut = router.path(game.route_trains(corp), corp, walk_limit: walk_limit)
    [routes.transform_keys(&:name).transform_values { |rs| rs.map(&:revenue) }, cut, router.walks]
  end

  it "stops after walk_limit visits, the same way every time" do
    full, full_cut, total = search(nil)
    expect(full_cut).to be(false)
    expect(total).to be > 2

    limited, cut, walks = search(2)
    expect(cut).to be(true)
    expect(walks).to be < total
    expect(search(2)).to eq([limited, cut, walks])
    expect(search(total)).to eq([full, false, total])
  end
end

# #324: a train bought from another railroad may cost anything from £1 up to the
# buyer's whole treasury (RB 11.6, Step::Train#spend_minmax), not only up to its
# face value; the set must equal the engine's span, and only in the major phase.
RSpec.describe Oe::LegalActions, "train from another railroad" do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:buyer) { start_major!(game, "LNWR", game.players[0]) }
  let(:seller) { start_major!(game, "GWR", game.players[1]) }
  let(:train) { game.depot.upcoming.find { |t| t.name == "3" } }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::BuyTrain) }
  let(:round) do
    buyer
    seller
    game.fulfill_train_obligation!(buyer)
    game.fulfill_train_obligation!(seller)
    game.depot.upcoming.select { |t| t.name == "2+2" }.each { |t| game.depot.remove_train(t) }
    game.instance_variable_set(:@first_or_complete, true)
    game.buy_train(seller, train, :free)
    enter_round!(game, game.operating_round(1))
  end

  def prices(legal)
    legal.send(:generate_buy_train, step, buyer).select { |a| a.train == train }.map(&:price)
  end

  def engine_span
    step.spend_minmax(buyer, train)
  end

  before do
    allow(game).to receive(:major_phase?).and_return(true)
    round
    allow(step).to receive(:current_entity).and_return(buyer)
  end

  it "keeps the face value as the ceiling without train_span (bot unchanged until #325)" do
    fund!(game, buyer, 1000 - buyer.cash)

    expect(prices(described_class.new(game)).max).to eq(train.price)
  end

  it "offers nothing from other railroads outside the major phase" do
    allow(game).to receive(:major_phase?).and_return(false)

    expect(step.buyable_trains(buyer)).not_to include(train)
    expect(prices(described_class.new(game, train_span: true))).to eq([])
  end

  it "spans the engine's whole range, above face value up to the treasury" do
    fund!(game, buyer, 1000 - buyer.cash)
    min, max = engine_span
    all = prices(described_class.new(game, train_span: true))

    expect([min, max]).to eq([1, buyer.cash])
    expect(max).to be > train.price
    expect(all.min).to eq(min)
    expect(all.max).to eq(max)
    expect(all).to include(train.price)
    expect(all.all? { |price| price.between?(min, max) }).to be(true)
  end

  it "keeps a sample within the span and with face value when limited" do
    fund!(game, buyer, 1000 - buyer.cash)
    min, max = engine_span
    sample = prices(described_class.new(game, train_span: true, limit: 4, rng: Random.new(3)))

    expect(sample).to include(min, max, train.price)
    expect(sample.all? { |price| price.between?(min, max) }).to be(true)
  end

  it "is capped at the treasury when the treasury is short: the president does not chip in (§11.6.4, #354)" do
    buyer.cash > 120 ? buyer.spend(buyer.cash - 120, game.bank) : fund!(game, buyer, 120 - buyer.cash)
    min, max = engine_span
    all = prices(described_class.new(game, train_span: true))

    expect(max).to eq(buyer.cash) # a train of another railroad is paid from the treasury only
    expect(all.max).to eq(max)
    expect(all).to include(min, max)
  end

  it "has every offered price accepted by the engine" do
    fund!(game, buyer, 1000 - buyer.cash)
    min, max = engine_span
    all = prices(described_class.new(game, train_span: true))

    expect { all.each { |price| step.check_spend(Engine::Action::BuyTrain.new(buyer, train: train, price: price)) } }.not_to raise_error
    expect { step.check_spend(Engine::Action::BuyTrain.new(buyer, train: train, price: max + 1)) }.to raise_error(Engine::GameError)
    expect { step.check_spend(Engine::Action::BuyTrain.new(buyer, train: train, price: min - 1)) }.to raise_error(Engine::GameError)
  end
end
