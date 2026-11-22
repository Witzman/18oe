# frozen_string_literal: true

require 'engine'
require_relative 'route_search'

module Oe
  # Enumerates concrete, legal Engine::Action instances for the entity (or
  # entities) the game is waiting for.
  #
  # The engine only names action *types* per step (`step.current_actions`,
  # e.g. ["bid", "pass"]); on 18xx.games the browser UI builds the concrete
  # actions. This is that logic for the server side: random harness (#31), bots
  # (#37) and the "what may I do now" API (#36) share it.
  #
  # Read-only: never mutates the game (the tile helpers briefly rotate shared
  # tile objects, which are reset before returning).
  #
  #   Oe::LegalActions.new(game, limit: 20, rng: Random.new(1)).call
  #     # => [#<Engine::Action::Bid ...>, #<Engine::Action::Pass ...>]
  #
  # `limit:` caps the number of actions generated for the large families
  # (tile lays, bid amounts, share bundles, ...), sampled with `rng`. A
  # `limit` of nil enumerates everything.
  class LegalActions
    # Kept for callers that rescue it. Since #125 an action type without a
    # generator is no longer raised: it is skipped and listed in #unsupported,
    # so one unbuildable type cannot make the whole game unplayable.
    class Unsupported < StandardError; end

    A = Engine::Action

    def self.call(game, **opts)
      new(game, **opts).call
    end

    # train_span: offer a train of another railroad at every price of the engine's
    # span (RB 11.6, #324), not only up to its face value. Off by default until
    # the bot chooses among those prices (#325): its picker takes the highest
    # affordable price (measured seed 1, 4 players: 460 of 552 purchases from
    # other railroads above face value).
    def initialize(game, limit: nil, rng: Random.new(0), compact: false, train_span: false)
      @train_span = train_span
      @game = game
      @limit = limit
      @rng = rng
      @unsupported = []
      @compact = compact
      @ranges = []
    end

    # Action types a step offered that have no generator, as "Step: type"
    # strings, in the order met (set by #call).
    attr_reader :unsupported

    # With `compact: true` the bid family (thousands of actions: one per amount)
    # is not expanded; it is described here instead (#91), one entry per
    # entity and company: {type: 'bid', entity:, company:, min:, max:, step:}.
    # Every amount min, min+step, ... max is a legal bid.
    attr_reader :ranges

    def call
      @unsupported = []
      @ranges = []
      return [] if @game.finished

      step = @game.round.active_step
      return [] unless step

      actions = step.active_entities.reject(&:closed?).flat_map do |entity|
        step.actions(entity).flat_map { |type| generate(type, step, entity) }
      end
      actions + acting_for(step) + company_actions(step) + bankrupt_actions + special_buy_actions
    end

    # The whole choice space of a tile lay, not sampled (#123): per affordable
    # hex the upgradeable tiles with their legal rotations,
    # [[hex, [[tile, [rotation, ...]], ...]], ...]. Tile rotations are reset
    # before returning.
    #
    # The engine's rotation check (Tracker#legal_tile_rotations) does not know
    # the game's TRACK_RESTRICTION (e.g. semi_restrictive: "Must use new track
    # or change city value"), it is only raised when the action is processed
    # (#309). Rotations the step would reject are left out here, using the
    # step's own Tracker#check_track_restrictions!.
    def lay_tile_options(step, entity)
      without_log do
        lay_tile_options_unlogged(step, entity)
      end
    end

    # Game#upgrade_cost logs the zone discount it applies; pricing a hex while
    # enumerating must not write to the real game log (#296).
    def without_log
      size = @game.log.size
      yield
    ensure
      @game.log.slice!(size..)
    end

    # Two passes: first every candidate on the real map (the graph is computed
    # once), then the track restriction, whose trial lays clear the graph; doing
    # them interleaved would recompute the real graph after every trial lay.
    def lay_tile_options_unlogged(step, entity)
      # a private's lay (§14.9) is the operating RR's: its graph, its tile points; no terrain price
      actor = entity.company? ? @game.current_entity : entity
      candidates = @game.hexes.filter_map do |hex|
        next unless step.available_hex(entity, hex)
        next unless entity.company? || affordable_lay?(entity, hex)

        # legal_rotations is per hex, and one tile object can be offered on several hexes
        [hex, step.upgradeable_tiles(entity, hex).map { |tile| [tile, affordable_rotations(entity, hex, tile)] }]
      end
      @connected = nil
      connected_paths(actor) unless candidates.empty?
      candidates.filter_map do |hex, tiles|
        tiles = tiles.map do |tile, legal|
          rotations = legal.select { |r| track_restriction_ok?(step, actor, hex, tile, r) }
          tile.rotate!(0)
          [tile, rotations]
        end.reject { |_, rotations| rotations.empty? }
        [hex, tiles] unless tiles.empty?
      end
    end

    # The lay's terrain cost fits the cash (a private's lay pays no terrain, §14.9).
    def affordable_lay?(entity, hex)
      @game.upgrade_cost(hex.tile, hex, entity, entity) <= entity.cash
    end

    # 18OE §11.1.6: the fee for the sea zones depends on the sides the tile connects to (Step::Track charges it as
    # the action's `extra_cost`), so a rotation whose fee the cash cannot pay is left out. On the real map, before
    # any trial lay.
    def affordable_rotations(entity, hex, tile)
      rotations = tile.legal_rotations.dup
      return rotations if entity.company? || !@game.respond_to?(:cross_water_tile_fee)

      terrain = @game.upgrade_cost(hex.tile, hex, entity, entity)
      rotations.select do |rotation|
        tile.rotate!(rotation)
        terrain + @game.cross_water_tile_fee(entity, hex, tile).to_i <= entity.cash
      end
    end

    # The company's connected paths on the real map, taken before any trial lay.
    def connected_paths(entity)
      @connected ||= @game.graph_for_entity(entity).connected_paths(entity).dup
    end

    # The cities a token may be placed in now (#123). A merge token (§10.5, #224) takes the place of the
    # minor's token (City#exchange_token), so the city is full by definition and `tokenable?` would refuse
    # it; the step's own `available_cities` (the minor's city) is the whole question.
    def token_targets(step, entity)
      return token_cities(step, entity) if step.is_a?(Engine::Game::G18OE::Step::MergeToken)

      tokens = step.available_tokens(entity)
      tokener = step.is_a?(Engine::Step::HomeToken) || entity.company? ? tokens.first.corporation : entity
      extra_slot = company_extra_slot?(step, entity)
      token_cities(step, entity).select do |city|
        city.tokenable?(tokener, free: false, tokens: tokens, extra_slot: extra_slot) && home_region_ok?(step, tokener, city) &&
          connected_for_token?(step, entity, city) &&
          (!step.respond_to?(:pass_city_ok?) || step.pass_city_ok?(entity, city))
      end
    end

    private

    # A private's token ability may use an extra position of the city (White
    # Cliffs Ferry in Lille); Tokener#place_token passes the same flag (#128).
    def company_extra_slot?(step, entity)
      return false unless entity.company? && step.respond_to?(:ability)

      step.ability(entity)&.then { |a| a.type == :token && a.extra_slot } ? true : false
    end

    # The engine runs Tracker#check_track_restrictions! inside lay_tile, after
    # hex.lay(tile) and with the graph cleared, so `connected_paths` already
    # holds the new tile's paths. Called on the untouched map, no new path is
    # ever "connected" and every lay on a hex with track (all upgrades, also
    # white hexes with a preprinted stub such as Dublin) was refused (#315).
    # A hex without track needs no graph (used_new_track starts true); the
    # common upgrade cases are decided by #semi_restrictive_verdict; the rest
    # runs the engine's own check, unchanged, on the map as it would look after
    # the lay (#with_tile_laid).
    def track_restriction_ok?(step, entity, hex, tile, rotation)
      return true unless step.respond_to?(:check_track_restrictions!)

      tile.rotate!(rotation)
      old_tile = hex.tile
      # without old track every new path is new track: only the graph-free part can fail
      return towns_kept?(old_tile, tile) if old_tile.paths.empty?

      verdict = semi_restrictive_verdict(entity, old_tile, tile)
      return verdict && towns_kept?(old_tile, tile) unless verdict.nil?

      with_tile_laid(entity, hex, tile) { step.check_track_restrictions!(entity, old_tile, tile) }
      true
    rescue Engine::GameError
      false
    end

    # The trial lay costs two graph computations, so the common cases are
    # decided without it, by the engine's own rule (Tracker#check_track_restrictions!,
    # :semi_restrictive): true/false when certain, nil when only the trial map can tell.
    # - false: every new path lies on an old one and no stop changes its revenue;
    # - true: a new path that is surely connected after the lay adds track or
    #   changes a stop's revenue. Surely connected: it lies on an old path that
    #   is connected now (laying only adds track), or meets such a path at a
    #   junction, a town, or a city the company may pass (own token or free slot).
    def semi_restrictive_verdict(entity, old_tile, tile)
      return nil unless @game.class::TRACK_RESTRICTION == :semi_restrictive

      old_paths = old_tile.paths
      info = tile.paths.map do |np|
        op = old_paths.find { |path| np <= path }
        changed = op && op.nodes.map(&:max_revenue).sort != np.nodes.map(&:max_revenue).sort
        [np, op, !op || changed]
      end
      return false if info.none? { |_, _, gain| gain }

      connected = connected_paths(entity)
      sure = info.select { |_, op, _| op && connected[op] }.map(&:first)
      return nil if sure.empty?

      joints = sure.flat_map { |path| joints_of(path, entity, old_tile) }
      surely = info.select { |np, _, _| sure.include?(np) || joints_of(np, entity, old_tile).intersect?(joints) }
      surely.any? { |_, _, gain| gain } ? true : nil
    end

    def joints_of(path, entity, old_tile)
      nodes = path.nodes.select { |node| !node.city? || passable_city?(node, entity, old_tile) }
      [*nodes, path.junction].compact
    end

    # The new city carries the tokens of the old city it replaces (Hex#city_map_for).
    def passable_city?(city, entity, old_tile)
      old = old_tile.hex.city_map_for(city.tile).key(city)
      return true unless old

      old.tokened_by?(entity) || old.tokens.include?(nil)
    end

    # The graph-free first check of Tracker#check_track_restrictions!.
    def towns_kept?(old_tile, tile)
      @game.class::ALLOW_REMOVING_TOWNS ||
        old_tile.city_towns.all? do |old_city|
          tile.city_towns.any? { |new_city| (old_city.exits - new_city.exits).empty? }
        end
    end

    # Puts `tile` on `hex` for the duration of the block, as far as the graph
    # sees it: the hex shows the new tile, and the tokens of each old city sit
    # in the city it maps to (Hex#city_map_for, the same map Hex#lay uses). The
    # graph is cleared before and after, so it is computed on the trial map and
    # then again on the real one. Everything is restored in `ensure`; tokens
    # themselves are not moved (their #city stays the old one).
    def with_tile_laid(entity, hex, tile)
      old_tile = hex.tile
      tile_hex = tile.hex
      saved = []
      hex.city_map_for(tile).compact.group_by(&:last).each do |new_city, pairs|
        saved << [new_city, new_city.tokens, new_city.extra_tokens]
        tokens = pairs.flat_map { |old_city, _| old_city.tokens.compact }
        tokens.concat([nil] * [new_city.tokens.size - tokens.size, 0].max)
        new_city.instance_variable_set(:@tokens, tokens)
        new_city.instance_variable_set(:@extra_tokens, pairs.flat_map { |old_city, _| old_city.extra_tokens })
      end
      routes = saved_routes(entity)
      hex.instance_variable_set(:@tile, tile)
      hex.instance_variable_set(:@paths, nil)
      old_tile.hex = nil
      tile.hex = hex
      @game.clear_graph_for_entity(entity)
      graph = @game.graph_for_entity(entity)
      graph.respond_to?(:without_ferry_prices) ? graph.without_ferry_prices { yield } : yield
    ensure
      if old_tile
        tile.hex = tile_hex
        old_tile.hex = hex
        hex.instance_variable_set(:@tile, old_tile)
        hex.instance_variable_set(:@paths, nil)
        saved.each do |city, tokens, extra|
          city.instance_variable_set(:@tokens, tokens)
          city.instance_variable_set(:@extra_tokens, extra)
        end
        @game.clear_graph_for_entity(entity)
        routes&.each { |graph_routes, copy| graph_routes.replace(copy) }
      end
    end

    # Graph#clear keeps a corporation's route info once it may buy a train
    # (`route_train_purchase` is sticky). A trial map must not leave such a
    # flag behind, so the route info is copied before and put back after.
    def saved_routes(entity)
      [@game.graph_for_entity(entity), @game.token_graph_for_entity(entity)].uniq.map do |graph|
        routes = graph.instance_variable_get(:@routes)
        [routes, routes.transform_values(&:dup)]
      end
    end

    # Actions a non-active entity issues while the step waits for someone else:
    # a player converts a regional they hold (issued by the corporation). The
    # president of a major that must buy a train may not sell shares (§11.6.4, #354).
    def acting_for(step)
      step.active_entities.select(&:player?).flat_map do |player|
        corporations_of(player).flat_map do |corporation|
          (step.actions(corporation) & %w[convert]).flat_map { |type| generate(type, step, corporation) }
        end
      end
    end

    # §11.6.4 (#354): the conversion of a major that cannot pay for its train. Its step does not
    # block (as in the engine's Bankrupt), so the active step never names it; the round's steps do.
    def bankrupt_actions
      entity = @game.round.current_entity
      return [] unless entity&.corporation?

      @game.round.steps.select { |s| s.is_a?(Engine::Step::Bankrupt) && s.active? }.flat_map do |step|
        step.actions(entity).include?('bankrupt') ? generate('bankrupt', step, entity) : []
      end
    end

    # Actions a private company issues itself (#128). The engine keeps these in
    # steps that are not the blocking one (Engine::Round::Base#active_step(company):
    # "steps for companies are non-blocking"), e.g. Step::SpecialToken for the
    # White Cliffs Ferry token while the corporation is in its Track step. The
    # candidates are the unclosed companies of the players behind the active
    # entities; a step decides itself whether the company may act now
    # (`step.actions(company)`), as the round does when it routes the action.
    def company_actions(step)
      entities = step.active_entities
      players = entities.map { |e| e.player? ? e : e.owner }.select { |o| o&.player? }.uniq
      players.flat_map do |player|
        player.companies.reject { |c| c.closed? || entities.include?(c) }.flat_map do |company|
          company_step = @game.round.active_step(company)
          next [] unless company_step

          company_step.actions(company).flat_map { |type| generate(type, company_step, company) }
        end
      end
    end

    def corporations_of(player)
      @game.corporations.select { |c| c.owner == player && !c.closed? }
    end

    def generate(type, step, entity)
      method = "generate_#{type}"
      unless respond_to?(method, true)
        note = "#{step.class.name.split('::').last}: #{type}"
        @unsupported << note unless @unsupported.include?(note)
        return []
      end

      send(method, step, entity)
    end

    def sample(list)
      return list if @limit.nil? || list.size <= @limit

      list.sample(@limit, random: @rng)
    end

    # Spread of amounts between min and max, always including both ends.
    def amounts(min, max, step_size = 1, exhaustive: false)
      return [] if max < min

      values = [min, max]
      if @limit.nil? || exhaustive
        values.concat((min..max).step(step_size).to_a)
      else
        values.concat(Array.new([@limit - 2, 0].max) { min + (@rng.rand(((max - min) / step_size) + 1) * step_size) })
      end
      values.uniq.sort
    end

    # ---- common -----------------------------------------------------------

    def generate_pass(_step, entity)
      [A::Pass.new(entity)]
    end

    def generate_skip(_step, entity)
      [A::Skip.new(entity)]
    end

    def generate_convert(step, entity)
      return [] unless entity.corporation? && step.respond_to?(:can_convert?) && step.can_convert?(entity, step.current_entity)

      [A::Convert.new(entity)]
    end

    def generate_bankrupt(_step, entity)
      [A::Bankrupt.new(entity)]
    end

    # ---- auction ----------------------------------------------------------

    def generate_bid(step, entity)
      target = step.auctioning
      companies = target ? [target] : step.companies
      companies.flat_map do |company|
        min = step.min_bid(company)
        next [] unless min

        max = step.max_bid(entity, company)
        prices = bid_prices(step, company, min, max)
        if @compact
          unless prices.empty?
            @ranges << { type: 'bid', entity: entity.id, company: company.id, min: prices.first, max: prices.last,
                         step: prices.size > 1 ? step.min_increment : 1 }
          end
          next []
        end
        prices.map { |price| A::Bid.new(entity, company: company, price: price) }
      end
    end

    def bid_prices(step, company, min, max)
      return [] if max < min
      # Top-row private: exactly face value, or (minors only) any higher bid.
      return [min] if step.respond_to?(:top_row?, true) && step.send(:top_row?, company) &&
                      !@game.company_becomes_minor?(company) && !step.auctioning

      amounts(min, max, step.min_increment, exhaustive: @compact)
    end

    # ---- stock round ------------------------------------------------------

    def generate_par(step, entity)
      return [] unless entity.player?

      @game.corporations.flat_map do |corporation|
        par_prices_for(step, entity, corporation).map do |price|
          A::Par.new(entity, corporation: corporation, share_price: price)
        end
      end
    end

    def par_prices_for(step, entity, corporation)
      return [] if corporation.closed?

      if corporation.type == :minor
        return [] unless step.respond_to?(:can_float_minor?) && step.can_float_minor?(entity)
        return [] unless entity.companies.any? { |c| c.id == corporation.id }
      elsif step.is_a?(Engine::Game::G18OE::Step::Concession)
        return [] unless concession_parrable?(step, entity, corporation)
      else
        return [] unless @game.can_par?(corporation, entity)
        return [] unless step.can_buy?(entity, corporation.shares.first&.to_bundle)
      end

      sample(step.get_par_prices(entity, corporation))
    end

    def concession_parrable?(step, entity, corporation)
      return false unless @game.can_par?(corporation, entity)

      step.get_par_prices(entity, corporation).any?
    end

    def generate_buy_shares(step, entity)
      return issue_actions(entity, step.redeemable_shares(entity), A::BuyShares) if step.is_a?(Engine::Step::IssueShares)

      bundles = []
      @game.corporations.each do |corporation|
        next if corporation.closed?

        bundles.concat(distinct_bundles(corporation.ipo_shares)) if corporation.ipoed
        bundles.concat(distinct_bundles(@game.share_pool.shares_by_corporation[corporation] || []))
      end
      bundles = bundles.select { |bundle| step.can_buy?(entity, bundle) }
      sample(bundles).map { |bundle| buy_shares_action(entity, bundle) }
    end

    def distinct_bundles(shares)
      shares.group_by { |s| [s.owner, s.percent, s.president] }.values.map { |group| group.first.to_bundle }
    end

    def buy_shares_action(entity, bundle)
      A::BuyShares.new(entity, shares: bundle.shares, share_price: bundle.share_price, percent: bundle.percent)
    end

    def issue_actions(entity, bundles, klass)
      sample(bundles).map do |bundle|
        klass.new(entity, shares: bundle.shares, share_price: bundle.share_price, percent: bundle.percent)
      end
    end

    def generate_sell_shares(step, entity)
      return issue_actions(entity, step.issuable_shares(entity), A::SellShares) if step.is_a?(Engine::Step::IssueShares)
      return [] unless entity.player?

      bundles = @game.corporations.flat_map { |corporation| @game.bundles_for_corporation(entity, corporation) }
      bundles = bundles.select { |bundle| step.can_sell?(entity, bundle) }
      sample(bundles).map do |bundle|
        A::SellShares.new(entity, shares: bundle.shares, share_price: bundle.share_price, percent: bundle.percent)
      end
    end

    # A buy_company / buy_corporation from another player is a direct trade (Chris' engine, #563): the buyer names
    # a whole price from 0 to their cash, no consent step, only in the first stock round before any other action.
    # With `compact: true` the prices are one range per target, like bids (#91); `company` is the target's id
    # (the private, or the minor corporation for buy_corporation).
    def generate_buy_company(step, entity)
      actions = step.buyable_bank_owned_companies(entity).map do |company|
        A::BuyCompany.new(entity, company: company, price: company.value)
      end
      step.purchasable_companies(entity).each do |company|
        actions.concat(trade_offers(step, entity, company) { |price| A::BuyCompany.new(entity, company: company, price: price) })
      end
      actions
    end

    def generate_buy_corporation(step, entity)
      @game.corporations.flat_map do |corporation|
        next [] unless step.can_buy_corporation?(entity, corporation)

        trade_offers(step, entity, corporation) { |price| A::BuyCorporation.new(entity, corporation: corporation, price: price) }
      end
    end

    def trade_offers(step, entity, target)
      min, max = step.price_range(entity, target)
      if @compact
        type = target.corporation? ? 'buy_corporation' : 'buy_company'
        @ranges << { type: type, entity: entity.id, company: target.id, min: min, max: max, step: 1 } if max >= min
        return []
      end
      sample(amounts(min, max, 5)).map { |price| yield price }
    end

    # ---- choose -----------------------------------------------------------

    def generate_choose(step, entity)
      case step
      when Engine::Game::G18OE::Step::BuySellParShares then stock_choices(step, entity)
      when Engine::Game::G18OE::Step::IssueShares then issue_choices(step, entity)
      else plain_choices(step, entity)
      end
    end

    def plain_choices(step, entity)
      return [] unless step.respond_to?(:choices)

      step.choices.keys.map { |choice| A::Choose.new(entity, choice: choice) }
    end

    def issue_choices(step, entity)
      step.choice_corporations(entity).map { |minor| A::Choose.new(entity, choice: minor.id) }
    end

    def stock_choices(step, entity)
      actions = []
      (entity.companies + @game.corporations).each do |target|
        next if target.respond_to?(:closed?) && target.closed?

        step.entity_choices(target).each_key { |choice| actions << A::Choose.new(entity, choice: choice, target: target) }
      end
      if step.non_private_choices_allowed?(entity)
        @game.corporations.each do |minor|
          actions << A::Choose.new(entity, choice: minor.id) if minor.type == :minor && step.can_merge?(entity, minor)
        end
      end
      actions
    end

    # ---- merge ------------------------------------------------------------

    def generate_merge(step, _entity)
      minor = step.mergeable_entity
      step.mergeable_entities.map { |major| A::Merge.new(minor, corporation: major) }
    end

    def generate_discard_train(step, entity)
      trains = if step.respond_to?(:trains) then step.trains(entity)
               else entity.trains
               end
      trains.map { |train| A::DiscardTrain.new(entity, train: train) }
    end

    # ---- operating round --------------------------------------------------

    def generate_lay_tile(step, entity)
      actions = lay_tile_options(step, entity).flat_map do |hex, tiles|
        tiles.flat_map { |tile, rotations| rotations.map { |rotation| [tile, hex, rotation] } }
      end
      sample(actions).map do |tile, hex, rotation|
        A::LayTile.new(entity, tile: tile, hex: hex, rotation: rotation)
      end
    end

    # §15.4 Minor D / §14.8 Hochberg: the private places its token on a hex (the action's target), as the step's
    # own `available_hex` allows (Chris' Step::Assign; the train marker of Minor L is a `choose`, 4c).
    def generate_assign(step, entity)
      hexes = @game.hexes.select { |hex| step.available_hex(entity, hex) }
      sample(hexes).map { |hex| A::Assign.new(entity, target: hex) }
    end

    # Port Authority (§11.3.5): the step is not blocking, so the active step never names it; the round's steps do.
    def special_buy_actions
      entity = @game.round.current_entity
      return [] unless entity&.corporation? && @game.round.operating?

      @game.round.steps.select { |s| s.is_a?(Engine::Step::SpecialBuy) }.flat_map do |step|
        step.actions(entity).include?('special_buy') ? generate('special_buy', step, entity) : []
      end
    end

    def generate_special_buy(step, entity)
      step.buyable_items(entity).map { |item| A::SpecialBuy.new(entity, item: item) }
    end

    # A private places the token of the corporation it acts for (#128): the
    # action names it as `tokener`, as the engine's own PlaceToken does.
    def generate_place_token(step, entity)
      return generate_transfer_token(step, entity) if step.is_a?(Engine::Game::G18OE::Step::TransferTokens)

      tokener = entity.company? ? @game.token_owner(entity) : nil
      sample(token_targets(step, entity)).flat_map { |city| place_token_actions(step, entity, city, tokener) }
    end

    # Chris' format (#563): a station token bought in 18OE names the charter token (`token_index`) and its cost
    # (`cost`, price plus the fee for the ferries and sea zones), always both. Home and merge tokens and a
    # private's token take no choice.
    def place_token_actions(step, entity, city, tokener)
      if entity.company? || !step.respond_to?(:selectable_token_choices)
        return [] if entity.company? && tokener && !company_token_affordable?(tokener, city)

        return [A::PlaceToken.new(entity, city: city, tokener: tokener)]
      end

      step.selectable_token_choices(entity, city).filter_map do |choice|
        next if choice[:cost] > entity.cash

        A::PlaceToken.new(entity, city: city, token_index: choice[:index], cost: choice[:cost])
      end
    end

    # A private's token is paid by the corporation that owns it (Step::Token#process_place_token checks its cash).
    def company_token_affordable?(tokener, city)
      # the private's token itself is free; the corporation pays the fee for ferries and sea zones (the step's check)
      @game.cross_water_token_fee(tokener, city) <= tokener.cash
    end

    # §11.2.x Transfer Tokens: the buyer replaces a token of another RR (`slot` of the city) with one of its own
    # charter tokens; `cost` is its price plus the transfer fee, which the step checks.
    def generate_transfer_token(step, buyer)
      offers = @game.hexes.flat_map do |hex|
        hex.tile.cities.flat_map do |city|
          (city.tokens + city.extra_tokens).each_with_index.flat_map do |token, slot|
            next [] unless step.can_replace_token?(buyer, token)

            step.selectable_token_choices(buyer, city).filter_map do |choice|
              next if choice[:cost] > buyer.cash

              A::PlaceToken.new(buyer, city: city, slot: slot, token_index: choice[:index], cost: choice[:cost])
            end
          end
        end
      end
      sample(offers)
    end

    # Tokens laid by operating (not home/merge tokens) must connect to a route
    # of the corporation; the step's own check says whether they do.
    def connected_for_token?(step, entity, city)
      return true unless step.is_a?(Engine::Step::Token)

      step.check_connected(entity, city, city.hex)
      true
    rescue Engine::GameError
      false
    end

    # 18OE: a minor's home token claims a track-rights region and pays for it from the minor's treasury
    # (Step::HomeToken: token.price = track_rights_cost).
    def home_region_ok?(step, tokener, city)
      return true unless step.is_a?(Engine::Game::G18OE::Step::HomeToken) && tokener.type == :minor

      region = @game.region_for_hex(city.hex)
      @game.region_available?(region) && tokener.cash >= @game.track_rights_cost(region)
    end

    def token_cities(step, entity)
      return step.available_cities.select { |city| step.available_city?(entity, city) } if step.respond_to?(:available_cities)

      @game.hexes.flat_map do |hex|
        step.available_hex(entity, hex) ? hex.tile.cities : []
      end
    end

    def generate_run_routes(_step, entity)
      routes = RoutePicker.new(@game, entity).call
      routes ? [A::RunRoutes.new(entity, routes: routes)] : []
    end

    # ---- Orient Express (RB 12.1, #136) -----------------------------------
    #
    # A major may combine two or more of its non-permanent trains that have not
    # run yet into one train for an Orient Express run. The engine's step
    # (G18OE::Step::Route#process_double_head_trains) builds the combined train
    # from the summed cities and towns; the train may then run only an Orient
    # Express route (G18OE::Game#check_other), and its components do not run on
    # their own this OR. A combination cannot be taken back (no undo, #34/#137),
    # so only combinations that can make an Orient Express run are offered:
    # one path search with all candidates combined (the largest train: any
    # route a smaller combination can run, it can run too) gives the fewest
    # cities an Orient Express route needs; a combination is offered when its
    # cities reach that. Towns never limit a combined train (its town row has
    # 'visit' 99). Trains of the same name are interchangeable, so each
    # multiset of names is offered once.
    def generate_double_head_trains(_step, entity)
      candidates = @game.double_head_candidates(entity)
      combos = RouteSearch.new(@game).combinations(candidates)
      return [] if combos.empty?

      need = OrientExpressReach.new(@game, entity).fewest_cities(candidates)
      return [] unless need

      fitting = combos.select { |trains| trains.sum { |t| @game.distance(t).first } >= need }
      sample(fitting).map { |trains| A::DoubleHeadTrains.new(entity, trains: trains) }
    end

    # The fewest cities (city and offboard stops) on an Orient Express route
    # that a train of the summed reach of `trains` finds, nil if it finds none.
    # Read-only: the trial train is never added to the depot or the
    # corporation. Its reach is built as the engine's step builds the combined
    # train (G18OE::Step::Route#combined_train!, private and adding the train
    # to the depot, hence repeated here). The search is the one run_routes uses
    # (RoutePicker, same walk limit), so an offered combination is one the
    # picker can route.
    class OrientExpressReach
      def initialize(game, entity)
        @game = game
        @entity = entity
      end

      def fewest_cities(trains)
        RouteSearch.new(@game).orient_express_routes(@entity, trains)
          .map { |route| route.visited_stops.count { |stop| !stop.town? } }.min
      end
    end

    # A private's own ability choice (Chris' Step::SpecialChoose, §14.10 Swift Metropolitan Line: `preserve`):
    # `choose_ability` with the ability's choice key; the receiving RR is the one operating.
    def generate_choose_ability(step, entity)
      step.choices_ability(entity).keys.map { |choice| A::ChooseAbility.new(entity, choice: choice.to_s) }
    end

    def generate_dividend(step, entity)
      step.dividend_types.map { |kind| A::Dividend.new(entity, kind: kind.to_s) }
    end

    def generate_buy_train(step, entity)
      return national_trains(step, entity) if entity.corporation? && entity.type == :national

      budget = train_budget(step, entity)
      step.buyable_trains(entity).flat_map do |train|
        min, max = step.spend_minmax(entity, train)
        # A depot train is bought at its variant price whatever spend_minmax says (EBUY_FROM_OTHERS never caps it at
        # the treasury): Step::Train#buy_train_action takes the rest from the president (RB 11.6.1, 11.6.4).
        max = train.from_depot? ? budget : [max, budget].min
        train_offers(step, entity, train, min, max).select do |_variant, price|
          price <= max && price.positive? && cheapest_if_contributing?(step, train, price, entity)
        end.map { |variant, price| A::BuyTrain.new(entity, train: train, price: price, variant: variant) }
      end
    end

    # §11.6.6 (#64): a national takes trains at price 0, in Chris' format (Step::NationalBuyTrains): a claim of a rusted
    # train from the Locomotive Works names the `variant`; an exchange (`exchange` = the rusted train it gives back)
    # is a swap for a higher rusted train (any variant) or an upgrade to a running train of the owner's majors
    # (its own name). The game lists the exchanges as [given, taken, variant, 0] (discountable_trains_for).
    def national_trains(step, entity)
      claims = step.buyable_trains(entity).flat_map do |train|
        train.variants.keys.map { |variant| A::BuyTrain.new(entity, train: train, price: 0, variant: variant) }
      end
      exchanges = @game.discountable_trains_for(entity).map do |given, train, variant, _discount|
        A::BuyTrain.new(entity, train: train, price: 0, variant: variant, exchange: given)
      end
      claims + exchanges
    end

    # [variant name, price] pairs. A depot train is offered once per variant the
    # engine allows (Step::Train#buyable_train_variants): 3 and 3+3, 4 and 4+4,
    # 5 and 5+5, 6 and 6+6, 7+7 and 4D, 8+8 and 5D (RB 11.6, the double-sided
    # cards), each at its own price (the variant's, as the engine's Step::Train checks it). A train of
    # another railroad keeps the side it was bought with: no variant.
    def train_offers(step, entity, train, min, max)
      return other_train_prices(train, min, max).map { |price| [nil, price] } unless train.from_depot?

      step.send(:buyable_train_variants, train, entity).map { |variant| [variant[:name], variant[:price]] }
    end

    # A train from another corporation: the engine's whole span (RB 11.6,
    # Step::Train#spend_minmax; buyable_trains offers such trains only in the
    # major phase, G18OE#can_buy_train_from_others?), not just up to face value.
    # The face value is always offered.
    def other_train_prices(train, min, max)
      max = [train.price, max].min unless @train_span
      prices = amounts(min, max, 10)
      prices << train.price if (min..max).cover?(train.price)
      prices.uniq.sort
    end

    # When the president has to chip in, the engine only allows the cheapest depot train.
    def cheapest_if_contributing?(step, train, price, entity)
      return true if price <= entity.cash

      step.send(:check_for_cheapest_train, train)
      true
    rescue Engine::GameError
      false
    end

    # Own cash, plus the president's when the step lets them contribute.
    def train_budget(step, entity)
      return entity.cash unless step.president_may_contribute?(entity)

      entity.cash + (entity.owner&.player? ? entity.owner.cash : 0)
    end

    # Picks, per train, the best-revenue non-conflicting route found by the
    # engine's path search. (AutoRouter#route, the combiner, is Opal-only.)
    class RoutePicker
      def initialize(game, entity)
        @game = game
        @entity = entity
      end

      def call
        router = RouteSearch.new(@game)
        router.pick(combined_first(router.train_routes(@entity)))
      end

      private

      # A train combined for the Orient Express (#136) may run only an Orient
      # Express route and its components do not run otherwise, so it picks
      # first; other trains keep the search's order. Without this a 3 took the
      # one Orient Express route and the combined train ran nothing.
      def combined_first(train_routes)
        train_routes.each_with_index
          .sort_by { |(train, _), i| [@game.combined_train?(train) ? 0 : 1, i] }
          .map(&:first)
      end
    end
  end
end
