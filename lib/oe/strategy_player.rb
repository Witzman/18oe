# frozen_string_literal: true

require_relative 'legal_actions'

module Oe
  # Picks one of the legal actions the way a sensible player would, so that a
  # whole game can be played without walking into the traps random play does
  # (undercapitalised companies that cannot pay their first 2+2). Ported from
  # the earlier simulation (~/18xx/scripts/simulate_18oe_2.rb, #84):
  #
  # - par so that 2 x par covers the track rights plus a 2+2 (metropolis
  #   regions higher); float minors you own before anything else
  # - withhold in the first operating round; withhold while the treasury is
  #   below the next train price
  # - train rush: buy the most expensive affordable train; otherwise issue
  #   shares, then the president sells shares
  # - auction: take the cheapest company at the minimum bid
  #
  # Everything it picks comes from `actions` (Oe::LegalActions), so it can
  # only play legal moves; it never makes the game illegal, only smarter.
  class StrategyPlayer
    TWO_PLUS_TWO = 100
    BUFFER_PAR_CASH = 200

    def initialize(game, rng: Random.new(0))
      @game = game
      @rng = rng
      @or_count = Hash.new(0)
    end

    def choose(actions)
      by_class = actions.group_by { |a| a.class.name.split('::').last }
      method = "choose_#{underscore(actions.first.class.name.split('::').last)}"
      Engine::Action.constants # (autoload no-op)
      # Order matters: first applicable specialised rule wins.
      %w[BuyTrain Dividend RunRoutes Bid Par Convert Merge DiscardTrain LayTile PlaceToken].each do |name|
        group = by_class[name]
        next unless group

        pick = send("pick_#{underscore(name)}", group, by_class)
        return pick if pick
      end
      pick_other(by_class)
    end

    private

    def underscore(name)
      name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    end

    def pick(list)
      list.sample(random: @rng)
    end

    # ---- auction ----------------------------------------------------------

    def pick_bid(bids, by_class)
      cheapest = bids.min_by { |bid| [bid.price, bid.company.value] }
      cheapest
    end

    # ---- par --------------------------------------------------------------

    def pick_par(pars, by_class)
      minors = pars.select { |a| a.corporation.type == :minor }
      candidates = minors.empty? ? pars : minors
      corporation_groups = candidates.group_by(&:corporation)
      corporation, options = corporation_groups.to_a.sample(random: @rng)
      target = target_par(corporation)
      fitting = options.select { |a| a.share_price.price * 2 >= target }
      fitting.min_by { |a| a.share_price.price }
    end

    def target_par(corporation)
      region = @game.class::CORPORATIONS_TRACK_RIGHTS[corporation.id]
      rights = region ? @game.track_rights_cost(region) : 40
      needed = rights + TWO_PLUS_TWO
      needed = [needed, BUFFER_PAR_CASH].max if metropolis_region?(region)
      needed
    end

    def metropolis_region?(region)
      return false unless region

      hexes = @game.class::NATIONAL_REGION_HEXES[region] || []
      hexes.any? { |coordinates| (hex = @game.hex_by_id(coordinates)) && @game.metropolis_hex?(hex) }
    end

    # ---- operating round --------------------------------------------------

    def pick_dividend(dividends, _by_class)
      entity = dividends.first.entity
      kinds = dividends.map(&:kind)
      kind = if poor?(entity) && kinds.include?('withhold') then 'withhold'
             elsif @or_count[entity.id].zero? && kinds.include?('withhold') then 'withhold'
             elsif kinds.include?('payout') then 'payout'
             elsif kinds.include?('half') then 'half'
             else kinds.first
             end
      @or_count[entity.id] += 1
      dividends.find { |a| a.kind == kind }
    end

    def poor?(entity)
      price = @game.depot.upcoming.first&.price || 0
      %i[major national].include?(entity.type) && entity.cash < price && entity.trains.size < @game.train_limit(entity)
    end

    def pick_run_routes(routes, _by_class)
      routes.first
    end

    def pick_buy_train(trains, by_class)
      entity = trains.first.entity
      affordable = trains.select { |a| a.price <= entity.cash }
      return affordable.max_by(&:price) unless affordable.empty?

      # Cannot pay: raise money first (issue shares, president sells shares).
      raise_money(by_class) || trains.min_by(&:price)
    end

    def raise_money(by_class)
      sells = by_class['SellShares']
      return nil unless sells

      sells.min_by { |a| a.bundle.percent }
    end

    def pick_lay_tile(tiles, by_class)
      entity = tiles.first.entity
      return nil unless by_class['Pass'] # forced

      # Do not spend the treasury on track while the first train is missing.
      return by_class['Pass'].first if entity.trains.empty? && entity.cash < BUFFER_PAR_CASH

      pick(tiles)
    end

    def pick_place_token(tokens, by_class)
      entity = tokens.first.entity
      pass = by_class['Pass']&.first
      return pick(tokens) unless pass
      return pass if entity.trains.empty? || entity.cash < TWO_PLUS_TWO + 40

      pick(tokens)
    end

    def pick_convert(converts, _by_class)
      pick(converts)
    end

    def pick_merge(merges, _by_class)
      pick(merges)
    end

    def pick_discard_train(discards, _by_class)
      discards.min_by { |a| a.train.price }
    end

    # ---- everything else: stock round, issue, choose, pass ---------------

    def pick_other(by_class)
      buys = by_class['BuyShares']
      sells = by_class['SellShares']
      if sells && !by_class['Pass'] && !buys
        return raise_money(by_class)
      end

      entity_actions = issue_or_buy(by_class)
      return entity_actions if entity_actions

      if (choose = by_class['Choose'])
        merges = choose.select { |a| a.target.nil? || a.choice.to_s.start_with?('offer', 'merge') }
        return pick(merges.empty? ? choose : merges) unless by_class['Pass']
      end
      return pick(by_class['Pass']) if by_class['Pass']

      pick(by_class.values.flatten)
    end

    def issue_or_buy(by_class)
      buys = by_class['BuyShares']
      sells = by_class['SellShares']
      entity = (buys || sells)&.first&.entity
      return nil unless entity

      if entity.corporation? && sells
        price = @game.depot.upcoming.first&.price || 0
        return sells.min_by { |a| a.bundle.percent } if entity.cash < price
        return by_class['Pass']&.first
      end
      return nil unless buys && entity.player?

      own = buys.select { |a| a.bundle.corporation.president?(entity) }
      pick(own.empty? ? buys : own)
    end
  end
end
