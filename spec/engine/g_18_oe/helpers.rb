# frozen_string_literal: true

module G18OESpecHelpers
  def new_game(players = %w[a b c], klass: Engine::Game::G18OE::Game, optional_rules: [])
    klass.new(players, seed: 1, optional_rules: optional_rules)
  end

  def act!(target, action)
    target.process_action(action)
    raise "#{action.class} by #{action.entity.name}: #{target.exception}" if target.is_a?(Engine::Game::Base) && target.exception

    target
  end

  def cell(game, price, type = nil)
    game.stock_market.market.flatten.compact.find { |sp| sp.price == price && (type.nil? || sp.type == type) }
  end

  def fund!(game, entity, amount = 2000)
    game.bank.spend(amount, entity)
    entity
  end

  def give_company!(player, company)
    company.owner = player
    player.companies << company
    company
  end

  def start_regional!(game, id, player, par: 60)
    regional = game.corporation_by_id(id)
    fund!(game, player)
    game.par_corporation(regional, cell(game, par, :par))
    game.share_pool.buy_shares(player, regional.shares.first)
    game.place_home_token(regional)
    game.minor_regional_order << regional
    regional
  end

  def float_regionals!(game, count, except: [])
    player = game.players.first
    game.corporations.select { |corporation| corporation.type == :regional && !corporation.ipoed }
      .reject { |corporation| except.include?(corporation.id) }
      .first(count)
      .each { |corporation| start_regional!(game, corporation.id, player) }
  end

  def start_major!(game, id, player)
    regional = start_regional!(game, id, player)
    Engine::Game::G18OE::Step::BuySellParShares.new(game, []).float_major(regional)
    regional
  end

  def start_minor!(game, id, player, zone)
    minor = game.corporation_by_id(id)
    game.share_pool.buy_shares(player, minor.shares.first.to_bundle, exchange: :free)
    fund!(game, minor, 120)
    game.claim_region!(minor, zone)
    game.minor_regional_order << minor
    minor
  end

  def take_treasury_shares!(game, player, corporation, count)
    fund!(game, player)
    count.times { game.share_pool.buy_shares(player, corporation.ipo_shares.first) }
  end

  def convert!(round, regional)
    president = regional.owner
    act!(round, Engine::Action::Convert.new(regional))
    act!(round, Engine::Action::Pass.new(president))
    act!(round, Engine::Action::BuyShares.new(president, shares: regional.ipo_shares.first, percent: 10))
    act!(round, Engine::Action::Pass.new(president)) if round.current_entity == president
    regional
  end

  def pass_until!(round, player)
    act!(round, Engine::Action::Pass.new(round.current_entity)) until round.current_entity == player
  end

  def lay_first_legal!(game, round, hex_id)
    entity = round.active_step.current_entity
    hex = game.hex_by_id(hex_id)
    tile = round.active_step.upgradeable_tiles(entity, hex).first
    act!(round, Engine::Action::LayTile.new(entity, tile: tile, hex: hex, rotation: tile.legal_rotations.first))
    tile
  end

  def enter_round!(game, round)
    game.instance_variable_set(:@round, round)
    round
  end

  def stock_round!(game, turn: 2)
    game.instance_variable_set(:@turn, turn)
    enter_round!(game, game.stock_round)
  end

  # --- Scenario building blocks (#365): reach a rule state by code, no seed game. ---

  # Advances the phase to `name` (a PHASES entry) without buying trains.
  def at_phase!(game, name)
    raise ArgumentError, "unknown phase #{name.inspect}" unless game.class::PHASES.any? { |p| p[:name] == name }

    game.phase.next! until game.phase.name == name
    game
  end

  # Gives `corporation` free trains from the depot's upcoming cards, one per name
  # (the first card of that name); with no names, the next card in the depot.
  # Returns the trains. Does not advance the phase beyond what buy_train triggers.
  def with_trains!(game, corporation, *names)
    names = [nil] if names.empty?
    names.map do |name|
      train = game.depot.upcoming.find { |t| name.nil? || t.name == name }
      raise ArgumentError, "no upcoming train #{name.inspect}" unless train

      game.buy_train(corporation, train, :free)
      train
    end
  end

  # A started regional that holds a train and has met its train obligation, so it can operate.
  def operating_regional!(game, id, player, trains: [], par: 60)
    start_regional!(game, id, player, par: par).tap do |regional|
      with_trains!(game, regional, *trains)
      game.fulfill_train_obligation!(regional)
    end
  end

  # Enters operating round `round_num` (optionally running its setup).
  def operating_round_for!(game, round_num = 1, setup: false)
    round = enter_round!(game, game.operating_round(round_num))
    round.setup if setup
    round
  end

  def round_step(round, klass)
    round.steps.find { |s| s.is_a?(klass) }
  end
end
