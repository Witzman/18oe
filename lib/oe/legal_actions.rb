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

    def initialize(game, limit: nil, rng: Random.new(0), compact: false)
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
      actions + acting_for(step)
    end

    private

    # Actions a non-active entity issues while the step waits for someone else:
    # a player converts a regional they hold (issued by the corporation), and
    # the president of a corporation that must buy a train may sell shares.
    def acting_for(step)
      step.active_entities.flat_map do |entity|
        others = entity.player? ? corporations_of(entity) : president_selling(step, entity)
        others.flat_map do |other|
          allowed = other.corporation? ? %w[convert] : %w[sell_shares]
          (step.actions(other) & allowed).flat_map { |type| generate(type, step, other) }
        end
      end
    end

    def president_selling(step, corporation)
      step.is_a?(Engine::Step::BuyTrain) && corporation.owner&.player? ? [corporation.owner] : []
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
      return issue_actions(entity, @game.redeemable_shares(entity), A::BuyShares) if step.is_a?(Engine::Step::IssueShares)

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
      return issue_actions(entity, @game.issuable_shares(entity), A::SellShares) if step.is_a?(Engine::Step::IssueShares)
      return [] unless entity.player?

      bundles = @game.corporations.flat_map { |corporation| @game.bundles_for_corporation(entity, corporation) }
      bundles = bundles.select { |bundle| step.can_sell?(entity, bundle) }
      sample(bundles).map do |bundle|
        A::SellShares.new(entity, shares: bundle.shares, share_price: bundle.share_price, percent: bundle.percent)
      end
    end

    def generate_buy_company(step, entity)
      actions = step.buyable_bank_owned_companies(entity).map do |company|
        A::BuyCompany.new(entity, company: company, price: company.value)
      end
      step.purchasable_companies(entity).each do |company|
        min, max = step.price_range(entity, company)
        sample(amounts(min, max, 5)).each { |price| actions << A::BuyCompany.new(entity, company: company, price: price) }
      end
      actions
    end

    def generate_buy_corporation(step, entity)
      @game.corporations.flat_map do |corporation|
        next [] unless step.can_buy_corporation?(entity, corporation)

        min, max = step.price_range(entity, corporation)
        sample(amounts(min, max, 5)).map { |price| A::BuyCorporation.new(entity, corporation: corporation, price: price) }
      end
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
      actions = []
      @game.hexes.each do |hex|
        next unless step.available_hex(entity, hex)
        next if @game.upgrade_cost(hex.tile, hex, entity, entity) > entity.cash

        tiles = step.upgradeable_tiles(entity, hex)
        tiles.each do |tile|
          tile.legal_rotations.each { |rotation| actions << [tile, hex, rotation] }
          tile.rotate!(0)
        end
      end
      sample(actions).map do |tile, hex, rotation|
        A::LayTile.new(entity, tile: tile, hex: hex, rotation: rotation)
      end
    end

    def generate_place_token(step, entity)
      tokens = step.available_tokens(entity)
      tokener = step.is_a?(Engine::Step::HomeToken) ? tokens.first.corporation : entity
      cities = token_cities(step, entity).select do |city|
        city.tokenable?(tokener, free: false, tokens: tokens) && home_region_ok?(step, tokener, city) &&
          connected_for_token?(step, entity, city)
      end
      sample(cities).map { |city| A::PlaceToken.new(entity, city: city) }
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

    # 18OE: a minor's home token claims a track-rights region and pays for it.
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

    def generate_dividend(step, entity)
      step.dividend_types.map { |kind| A::Dividend.new(entity, kind: kind.to_s) }
    end

    def generate_buy_train(step, entity)
      budget = train_budget(step, entity)
      step.buyable_trains(entity).flat_map do |train|
        min, max = step.spend_minmax(entity, train)
        max = [max, budget].min
        prices = train.from_depot? ? [train.price] : amounts(min, [train.price, max].min, 10)
        prices.select { |price| price <= max && price.positive? && cheapest_if_contributing?(step, train, price, entity) }.map { |price| A::BuyTrain.new(entity, train: train, price: price) }
      end
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
        train_routes, = router.path(@game.route_trains(@entity).sort_by(&:price), @entity)
        chosen = []
        train_routes.each do |train, candidates|
          route = candidates.find { |candidate| compatible?(router, chosen, train, candidate) }
          chosen << route if route
        end
        settle(chosen)
        chosen
      end

      private

      # Each route validates itself against the other chosen routes, so the
      # shared `routes` list must be the final one before the action is built.
      def settle(chosen)
        chosen.each do |route|
          route.clear_cache!(only_routes: true)
          route.routes = chosen
        end
      end

      def compatible?(router, chosen, _train, candidate)
        trial = chosen + [candidate]
        trial.each { |r| r.routes = trial }
        router.real_revenue(trial) >= 0 && candidate.revenue.positive?
      rescue Engine::GameError
        false
      ensure
        settle(chosen)
      end
    end
  end
end
