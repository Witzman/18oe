# frozen_string_literal: true

require "engine"
require_relative "legal_actions"

module Oe
  # The JSON view model (#35): everything the client may render, as plain
  # hashes/arrays/strings/numbers. Read-only; never returns Engine objects;
  # stable ids; deterministic order (players in seat order, corporations in
  # engine order, hexes by id). The fixed map geometry is delivered separately
  # (#43) — `map` holds only what changes during a game.
  #
  #   Oe::View.render(game, viewer: "p0", seq: 123)
  module View
    ROUND_TYPES = {
      "Auction" => "auction",
      "Concession" => "concession",
      "Stock" => "stock",
      "Operating" => "operating",
      "Consolidation" => "consolidation",
    }.freeze

    module_function

    # viewer:  engine player id (e.g. "p0") or nil for a spectator
    # seq:     the log position this state belongs to (default: last action id)
    # log:     number of trailing log lines (nil = none)
    # actions: include the viewer's legal actions in `prompt` (costs an enumeration)
    def render(game, viewer: nil, seq: nil, log: 40, actions: true, actions_limit: nil)
      {
        meta: meta(game, seq),
        players: game.players.each_with_index.map { |p, i| player(game, p, i, viewer) },
        corporations: game.corporations.map { |c| corporation(game, c) },
        market: market(game),
        depot: depot(game),
        tiles: tiles(game),
        bank: { cash: game.bank.cash },
        auction: auction(game),
        concession: concession(game),
        companies: companies(game, viewer),
        zones: zones(game),
        map: map(game),
        log: log_lines(game, log),
        prompt: prompt(game, viewer, actions, actions_limit),
      }
    end

    def meta(game, seq)
      round = game.round
      entity = current_entity(game)
      phase = game.phase
      {
        seq: seq || game.raw_actions.last&.fetch("id", 0) || 0,
        game_id: game.id,
        finished: game.finished ? true : false,
        round: {
          type: round_type(round),
          number: round.respond_to?(:round_num) ? round.round_num : nil,
          turn: game.turn,
          description: safe { game.round_description(round_type(round).capitalize) },
        },
        phase: {
          name: phase.name.to_s,
          tiles: phase.tiles.map(&:to_s),
          operating_rounds: phase.operating_rounds,
          status: Array(phase.status).map(&:to_s),
          train_limits: train_limits(phase.current),
          next: next_phase(phase),
        },
        rr_phase: rr_phase(game),
        railroads: railroads(game),
        operating_order: operating_order(game),
        priority: priority(game),
        current: entity && entity_ref(entity),
        active_players: game.active_players.map(&:id),
        standings: game.result.map { |id, value| { player: id, value: value } },
        winner: game.finished ? game.result.keys.first : nil,
      }
    end

    def round_type(round)
      ROUND_TYPES.fetch(round.class.name.split("::").last, round.class.name.split("::").last.downcase)
    end

    def current_entity(game)
      return if game.finished

      game.current_entity
    rescue StandardError
      nil
    end

    def entity_ref(entity)
      kind = entity.player? ? "player" : "corporation"
      ref = { kind: kind, id: entity.id }
      ref[:owner] = entity.owner.id if kind == "corporation" && entity.owner.respond_to?(:id) && entity.owner.player?
      ref
    end

    def player(game, player, index, viewer)
      {
        id: player.id,
        name: player.name,
        order: index, # position in the current priority order; 0 = priority deal
        cash: player.cash,
        value: game.player_value(player),
        certs: game.num_certs(player),
        cert_limit: game.cert_limit(player),
        shares: player.shares_by_corporation(sorted: true).filter_map do |corp, shares|
          next if shares.empty?

          { corporation: corp.id, percent: shares.sum(&:percent), president: shares.any?(&:president) }
        end.sort_by { |h| h[:corporation].to_s },
        companies: player.companies.sort_by(&:id).map { |c| company(game, c, viewer == player.id) },
      }
    end

    def company(game, company, own)
      hidden = game.face_down_private?(company) && !own
      {
        id: company.id,
        name: hidden ? nil : company.name,
        value: hidden ? nil : company.value,
        face_down: game.face_down_private?(company) ? true : false,
      }
    end

    def corporation(game, corp)
      holders = share_holders(game, corp)
      {
        id: corp.id,
        name: corp.full_name,
        type: corp.type.to_s,
        president: corp.owner.respond_to?(:player?) && corp.owner.player? ? corp.owner.id : nil,
        ipoed: corp.ipoed ? true : false,
        floated: corp.floated? ? true : false,
        closed: corp.closed? ? true : false,
        cash: corp.cash,
        share_price: corp.share_price&.price,
        par_price: corp.par_price&.price,
        shares: holders,
        reserved: reserved(game, corp),
        trains: corp.trains.map { |t| train(t) },
        tokens: corp.tokens.map { |t| { used: t.used ? true : false, hex: t.city&.hex&.id } },
        last_run: last_run(corp),
        track_rights: Array(safe { game.track_rights_zones(corp) }).map(&:to_s),
        orient_express_marker: game.orient_express_marker?(corp) ? true : false,
        status: Array(safe { game.status_array(corp) }).flatten.map(&:to_s),
        regional_state: regional_state(game, corp),
      }
    end

    # Who operates when (#122). During an operating round: that round's fixed
    # entity list (`round.entities`, = `game.operating_order` at its start) with
    # `done` for those before the current one. Otherwise: the order the next
    # operating round would have (`game.operating_order`), nothing done.
    def operating_order(game)
      round = game.round
      if round.is_a?(Engine::Round::Operating)
        index = game.finished ? round.entities.size : round.entity_index
        round.entities.each_with_index.map { |c, i| { id: c.id, done: i < index } }
      else
        game.operating_order.map { |c| { id: c.id, done: false } }
      end
    end

    # Player ids in the order of the next stock round, priority deal first
    # (`game.priority_deal_player`, as in the engine's `reorder_players`).
    def priority(game)
      ids = game.players.reject(&:bankrupt).map(&:id)
      deal = safe { game.send(:priority_deal_player) }&.id # private in Engine::Game::Base
      i = ids.index(deal) || 0
      ids.rotate(i)
    end

    # Railroad phase (#121): auction, concession, regional_minor (regionals and
    # minors still being floated), major (`major_phase?`: all minors floated, the
    # unfloated regionals gone) or consolidation (the consolidation round, which
    # interrupts the major phase).
    def rr_phase(game)
      case round_type(game.round)
      when "auction", "concession", "consolidation" then round_type(game.round)
      else game.major_phase? ? "major" : "regional_minor"
      end
    end

    # Per regional exactly one state; nil for any other corporation. A converted
    # regional has become a major (type changes) but keeps its regional id.
    def regional_state(game, corp)
      return unless game.class::CORPORATIONS_TRACK_RIGHTS.key?(corp.id)

      if corp.type == :major then "converted"
      elsif corp.closed? then corp.par_price ? "closed" : "removed"
      elsif corp.floated? then "floated"
      elsif corp.ipoed then "parred"
      else "unparred"
      end
    end

    REGIONAL_STATES = %w[unparred parred floated converted removed closed].freeze

    # Closed corporations leave `game.corporations`, so the six removed
    # regionals are looked up by id.
    def regional_states(game)
      game.class::CORPORATIONS_TRACK_RIGHTS.keys.map do |id|
        { id: id, state: regional_state(game, game.corporation_by_id(id)) }
      end
    end

    def railroads(game)
      list = regional_states(game)
      tally = list.map { |r| r[:state] }.tally
      regionals = REGIONAL_STATES.to_h { |s| [s.to_sym, tally.fetch(s, 0)] }
      {
        minors: { floated: game.minor_floated_regions.size, total: game.class::CORPORATIONS.count { |c| c[:type].to_s == "minor" } },
        regionals: regionals.merge(
          total: tally.values.sum,
          floated: regionals[:floated] + regionals[:converted], # floated at some point, converted ones included
          max_floated: game.class::MAX_FLOATED_REGIONALS,
          max_removed: tally.values.sum - game.class::MAX_FLOATED_REGIONALS,
        ),
        regional_states: list,
      }
    end

    # The concession round (#121): CON1..CON10 in execution order with the
    # holder at the start of the round and status done / current / open. The
    # current one stays current while its home token is still to be placed. nil
    # before the concession round began.
    def concession(game)
      owners = game.concession_owners
      return unless owners

      running = round_type(game.round) == "concession" && !game.finished ? game.round.current_concession : nil
      game.concessions.map do |c|
        status = c.equal?(running) ? "current" : c.closed? ? "done" : "open"
        { id: c.id, name: c.name, owner: owners[c.id], status: status }
      end
    end

    # Track-rights zones for minors (#121): home-token price, whether a chit is
    # still free, who took one. `discount` is the zone's percent discount.
    def zones(game)
      klass = game.class
      taken = game.minor_floated_regions.group_by { |_, zone| zone }
      klass::MINOR_TRACK_RIGHTS_CHITS.keys.map do |zone|
        left = game.minor_available_regions[zone] || 0
        {
          id: zone,
          price: game.track_rights_cost(zone),
          chits_left: left,
          free: left.positive?,
          taken_by: taken.fetch(zone, []).map(&:first).sort,
          discount: klass::ZONE_DISCOUNT_ZONES.include?(zone) ? (klass::ZONE_DISCOUNT_RATE * 100).to_i : 0,
        }
      end
    end

    # Percent per holder (the sum over all holders is 100 for an ipoed corporation) and the ids of the
    # shares each holds, so a client can tell which share of an offered `buy_shares` comes from the IPO
    # (treasury) and which from the market (#47).
    def share_holders(game, corp)
      pool = game.share_pool
      shares = game.shares_for_corporation(corp)
      corp.share_holders.filter_map do |holder, percent|
        next if percent.to_i.zero?

        owner =
          if holder.respond_to?(:player?) && holder.player? then holder.id
          elsif holder.equal?(pool) then "market"
          elsif holder.equal?(corp.ipo_owner) then "ipo"
          else holder.respond_to?(:id) ? holder.id.to_s : holder.class.name
          end
        ids = shares.select { |s| s.owner.equal?(holder) }.map(&:id)
        [owner, percent, ids]
      end.sort_by { |owner, _, _| owner }.map { |owner, percent, ids| { holder: owner, percent: percent, ids: ids } }
    end

    def reserved(game, corp)
      share = safe { game.reserved_share(corp) }
      share && { percent: share.percent, player: corp.owner.respond_to?(:id) ? corp.owner.id : nil }
    end

    def train(train)
      {
        id: train.id,
        name: train.name,
        price: train.price,
        distance: train.distance.is_a?(Array) ? train.distance.map { |d| d.respond_to?(:to_h) ? d.to_h : d } : train.distance,
        rusts_on: train.rusts_on,
        obsolete_on: train.obsolete_on,
      }
    end

    def last_run(corp)
      info = corp.operating_history.to_a.last&.last
      return unless info

      {
        revenue: info.revenue,
        dividend: info.dividend_kind&.to_s,
        # Per train (#119): the run as driven. `segments` are the paths in order
        # (hex id, exit edges, node indexes); `stops` the places visited with
        # their revenue for that train. Captured when the run was paid out.
        routes: info.routes.keys.map { |t| run_detail(info, t) },
      }
    end

    def run_detail(info, train)
      {
        train: train.id,
        name: train.name,
        revenue: info.revenues[train],
        hexes: info.routes[train].flatten.map(&:to_s),
        segments: info.segments[train],
        stops: info.stops[train],
      }
    end

    def market(game)
      { rows: game.stock_market.market.map do |row|
        row.map do |cell|
          cell && { price: cell.price, type: cell.type&.to_s, corporations: cell.corporations.map(&:id) }
        end
      end }
    end

    def depot(game)
      depot = game.depot
      {
        available: depot.depot_trains.map { |t| train(t).merge(owner: t.owner.respond_to?(:id) ? t.owner.id : nil) },
        upcoming: depot.upcoming.size,
        next: depot.upcoming.first&.name,
        discarded: depot.discarded.map(&:name),
        schedule: schedule(game),
      }
    end

    # Train limit per corporation type of a phase entry (#123): the phase hash's
    # `train_limit`, a plain number for games without types.
    def train_limits(entry)
      limit = entry[:train_limit]
      limit.is_a?(Hash) ? limit.to_h { |type, n| [type.to_s, n] } : limit
    end

    # The phase that follows (#123): its name, the train whose purchase starts
    # it (`on`), tiles and limits; nil in the last phase.
    def next_phase(phase)
      nxt = phase.upcoming
      return unless nxt

      { name: nxt[:name].to_s, on: nxt[:on]&.to_s, tiles: Array(nxt[:tiles]).map(&:to_s),
        operating_rounds: nxt[:operating_rounds], train_limits: train_limits(nxt) }
    end

    # The trains still to come (#123), by name in buying order: how many, the
    # price, the phase the first purchase starts (`phase_on`: the phase whose
    # `on` is this train) and which trains it rusts or makes obsolete.
    def schedule(game)
      phases = game.class::PHASES
      game.depot.upcoming.group_by(&:name).map do |name, trains|
        first = trains.first
        {
          name: name,
          count: trains.size,
          price: first.price,
          phase_on: phases.find { |ph| ph[:on].to_s == name }&.fetch(:name)&.to_s,
          rusts_on: first.rusts_on,
          obsolete_on: first.obsolete_on,
          available_on: first.available_on,
        }
      end
    end

    # The tile supply (#123): per tile name how many are still in the game
    # (not on the map), its colour and whether the current phase allows it.
    def tiles(game)
      allowed = game.phase.tiles.map(&:to_s)
      game.tiles.group_by { |t| t.name.to_s }.sort.map do |name, list|
        first = list.first
        { name: name, color: first.color.to_s, remaining: list.size, unlimited: list.any?(&:unlimited) ? true : false,
          available: allowed.include?(first.color.to_s) }
      end
    end

    # The opening auction (#120): the unsold cards in row order, nil when no
    # auction is running. A card is a private, a minor or a concession; `min_bid`
    # is the step's own minimum (face value less the all-pass discount for the
    # top row, else the highest bid plus the increment); `bid` the highest bid.
    # `current` is the card in the open auction among all players (once someone
    # bid above face value on a minor), `open_bidders` who is still in it.
    def auction(game)
      return if game.finished

      step = game.round.active_step
      return unless step.respond_to?(:tiered_auction_companies) && step.respond_to?(:open_bidders)

      cards = step.companies
      {
        top_row: cards.first&.auction_row,
        increment: step.min_increment,
        cards: cards.map { |c| auction_card(game, step, c) },
        current: step.auctioning&.id,
        to_act: step.active_entities.map(&:id),
        passed: game.players.select(&:passed?).map(&:id),
        open_bidders: step.open_bidders.map(&:id),
      }
    end

    def auction_card(game, step, company)
      high = step.bids.fetch(company, []).max_by(&:price)
      {
        id: company.id,
        name: company.name,
        kind: if company.type == :concession then "concession"
              elsif game.company_becomes_minor?(company) then "minor"
              else "private"
              end,
        row: company.auction_row,
        value: company.value,
        revenue: company.revenue,
        discount: company.discount,
        min_bid: step.min_bid(company),
        bid: high && { player: high.entity.id, price: high.price },
      }
    end

    # Only hexes that differ from the printed map: a laid tile, tokens, a patronage marker.
    def map(game)
      game.hexes.sort_by(&:id).filter_map do |hex|
        tile = hex.tile
        tokens = tile.cities.each_with_index.map { |city, i| { city: i, corporations: city.tokens.compact.map { |t| t.corporation&.id } } }
        tokens.select! { |t| t[:corporations].any? }
        laid = tile.name != hex.original_tile.name
        next unless laid || tokens.any? || tile.patronage

        {
          hex: hex.id,
          tile: { name: tile.name.to_s, rotation: tile.rotation, color: tile.color.to_s },
          tokens: tokens,
          patronage: tile.patronage&.transform_keys(&:to_s),
        }.compact
      end
    end

    def log_lines(game, count)
      return [] unless count&.positive?

      game.log.last(count).map { |e| { action: e.action_id, text: e.message.to_s } }
    end

    def prompt(game, viewer, with_actions, limit)
      step = game.finished ? nil : game.round.active_step
      mine = viewer && !game.finished && game.active_players.any? { |p| p.id == viewer }
      list = []
      unsupported = []
      ranges = []
      legal = nil
      offered = []
      if mine && with_actions
        legal = Oe::LegalActions.new(game, limit: limit, rng: Random.new(0), compact: true)
        offered = legal.call
        list = offered.map { |a| a.to_h.reject { |k, _| %w[id created_at user].include?(k) } }
        unsupported = legal.unsupported
        ranges = legal.ranges
      end
      {
        step: step && step.class.name.split("::").last,
        types: step ? Array(step.current_actions).map(&:to_s) : [],
        viewer_to_act: mine ? true : false,
        actions: list,
        # Action types the step offers that the server cannot enumerate (#125).
        # The game stays playable; the client may offer a generic fallback.
        unsupported: unsupported,
        # Families with too many members to list (#91): bids as ranges. Every
        # amount min, min+step .. max is legal; send a normal bid action.
        ranges: ranges,
        # The step's own texts (#124), English as the engine has them: what the
        # step is, its help, the label of its pass button, the question of a
        # `choose` and the label of every offered choice.
        description: step && safe { step.description },
        help: step && safe { step.help }.then { |h| h.to_s.empty? ? nil : h },
        pass_description: step && safe { step.pass_description },
        choice_name: step && safe { step.respond_to?(:choice_name) ? step.choice_name : nil },
        choices: choices(game, step, offered),
        acting_as: acting_as(game, step, list),
        context: context(game, step, mine && with_actions ? legal : nil, offered),
      }
    end

    # One entry per offered `choose` action: the choice id, its target (a company
    # or corporation id, or nil) and the label the engine gives it. Where the step
    # has no text for a choice the label is the choice id itself, never empty.
    def choices(game, step, offered)
      offered.grep(Engine::Action::Choose).map do |a|
        { choice: a.choice.to_s, target: a.target&.id, entity: a.entity.id, label: choice_label(game, step, a) }
      end
    end

    def choice_label(game, step, action)
      choice = action.choice
      label =
        if action.target && step.respond_to?(:entity_choices) then safe { step.entity_choices(action.target)[choice] }
        elsif step.respond_to?(:choices) then safe { step.choices[choice] }
        end
      if label.nil? && step.respond_to?(:entity_choices)
        corp = safe { game.corporation_by_id(choice) }
        label = safe { step.entity_choices(corp)[choice] } if corp
      end
      label.to_s.empty? ? choice.to_s : label.to_s
    end

    # Who the offered actions are issued for (#91, #123): one entry per acting
    # entity in `actions`, the entity the step waits for first (`primary`), the
    # others are "also possible" (a president selling shares for a corporation
    # that must buy a train, a player converting a regional).
    def acting_as(game, step, list)
      current = step && safe { step.current_entity }&.id
      list.group_by { |a| a["entity"] }.map do |id, actions|
        entity = game.get(actions.first["entity_type"], id)
        {
          entity: id,
          kind: entity.player? ? "player" : "corporation",
          primary: id == current || (current.nil? && entity.player?),
          types: actions.map { |a| a["type"] }.uniq,
        }
      end
    end

    # The numbers of the active operating step (#123), as the engine knows them,
    # so the client never recomputes rules. One key per step family, nil when the
    # active step is another one:
    #   track:    tile points of the corporation, and per hex the cost (with its
    #             parts) and the tiles with their legal rotations
    #   token:    the price of the next token and per legal city its price
    #   dividend: per option the amount per share, to the treasury, the new price
    #   train:    train limit, obligation, reserved 2+2, president's contribution
    #   stock:    price and new share price of the offered share actions (#47)
    # `legal` (an Oe::LegalActions) is given only for the viewer to act: choice
    # spaces that need the enumeration (tile lays, token targets) are nil otherwise.
    def context(game, step, legal, offered = [])
      empty = { track: nil, token: nil, dividend: nil, train: nil, stock: nil }
      return empty.merge(stock: safe { stock_context(game, step, offered) }) if stock_step?(step)
      return empty unless step

      entity = safe { step.current_entity }
      return empty unless entity&.corporation?

      {
        track: step.is_a?(Engine::Game::G18OE::Step::Track) ? safe { track_context(game, step, entity, legal) } : nil,
        token: token_step?(step) ? safe { token_context(game, step, entity, legal) } : nil,
        dividend: step.is_a?(Engine::Step::Dividend) ? safe { dividend_context(game, step, entity) } : nil,
        train: step.is_a?(Engine::Step::BuyTrain) ? safe { train_context(game, step, entity) } : nil,
        stock: nil,
      }
    end

    # Every private, minor charter and concession and where it is now (#124,
    # D16): with a player, a corporation, the bank (not yet sold) or nobody
    # (closed). `abilities` are the card's live abilities with `used` and
    # `remaining` (nil = unlimited); a face-down private shows none to others.
    # The static texts are in the catalog (Oe::Catalog).
    def companies(game, viewer)
      game.companies.map do |c|
        own = c.owner.respond_to?(:player?) && c.owner.player? && c.owner.id == viewer
        hidden = game.face_down_private?(c) && !own
        {
          id: c.id,
          kind: if c.type == :concession then "concession"
                elsif game.company_becomes_minor?(c) then "minor"
                else "private"
                end,
          owner: company_owner(game, c),
          closed: c.closed? ? true : false,
          face_down: game.face_down_private?(c) ? true : false,
          abilities: hidden ? [] : c.all_abilities.map { |a| { type: a.type.to_s, used: a.used? ? true : false, remaining: a.count } },
        }
      end
    end

    def company_owner(game, company)
      owner = company.owner
      return if company.closed? || owner.nil?

      if owner.respond_to?(:player?) && owner.player? then { kind: "player", id: owner.id }
      elsif owner.respond_to?(:corporation?) && owner.corporation? then { kind: "corporation", id: owner.id }
      elsif owner.equal?(game.bank) then { kind: "bank", id: nil }
      else { kind: "other", id: owner.respond_to?(:id) ? owner.id.to_s : nil }
      end
    end

    def stock_step?(step)
      # The concession step is a subclass but has its own panel (#172) and a par there may cost nothing (par_only).
      step.is_a?(Engine::Game::G18OE::Step::BuySellParShares) && !step.is_a?(Engine::Game::G18OE::Step::Concession)
    end

    # The money of the share actions on offer (#47): per offered `buy_shares` / `sell_shares` the cost or the
    # proceeds, where the shares come from (`ipo` = treasury, `market`), and for a sale the share price after it
    # (nil unless every share moves the price one step down, the rule of this game). Matched to the action by
    # type and share ids; `shares` are the ids of the bundle. Only for the viewer to act.
    #   stock: { bundles: [{ type:, corporation:, shares: [id], percent:, source:, price:, new_price: }],
    #            pars: [{ corporation:, share_price: id, price:, percent: }] }
    def stock_context(game, step, offered)
      bundles = offered.filter_map do |a|
        next unless a.is_a?(Engine::Action::BuyShares) || a.is_a?(Engine::Action::SellShares)

        bundle = a.bundle
        corp = bundle.corporation
        buy = a.is_a?(Engine::Action::BuyShares)
        owner = bundle.owner
        {
          type: buy ? 'buy_shares' : 'sell_shares',
          corporation: corp.id,
          shares: bundle.shares.map(&:id),
          percent: bundle.percent,
          source: owner.equal?(corp.ipo_owner) ? 'ipo' : (owner.respond_to?(:share_pool?) && owner.share_pool? ? 'market' : owner.id),
          price: buy ? step.modify_purchase_price(bundle) : bundle.price,
          new_price: buy ? nil : price_after_sale(game, corp, bundle),
        }
      end
      { bundles: bundles, pars: par_prices(offered) }
    end

    # What the president's share costs at each offered par price (#47); a minor is floated in exchange for
    # its private, so it costs nothing in cash. `share_price` is the id the `par` action carries.
    def par_prices(offered)
      offered.filter_map do |a|
        next unless a.is_a?(Engine::Action::Par)

        corp = a.corporation
        sp = a.share_price
        bundle = corp.ipo_shares.first&.to_bundle
        next unless bundle

        bundle.share_price = sp.price
        { corporation: corp.id, share_price: sp.id, price: corp.type == :minor ? 0 : bundle.price, percent: bundle.percent }
      end
    end

    def price_after_sale(game, corp, bundle)
      return nil unless game.sell_movement(corp) == :down_share && corp.share_price

      market = game.stock_market
      coords = corp.share_price.coordinates
      bundle.num_shares.times do
        # The same rule as StockMarket#move: a step onto a cell without normal movement is not taken.
        nxt = market.down(corp, coords)
        cell = nxt && market.share_price(nxt)
        coords = nxt if cell&.normal_movement?
      end
      market.share_price(coords)&.price
    rescue StandardError
      nil
    end

    def token_step?(step)
      step.is_a?(Engine::Step::Token) || step.is_a?(Engine::Step::HomeToken)
    end

    # The engine logs discounts while it prices a tile (`upgrade_cost`); reading
    # a price for the view must not add to the game log.
    def without_log(game)
      size = game.log.size
      yield
    ensure
      game.log.slice!(size..)
    end

    def track_context(game, step, entity, legal)
      budget = step.get_tile_lay(entity)
      {
        points: { budget: budget, used: step.points_used, left: step.points_left(entity) },
        hexes: legal && without_log(game) { track_hexes(game, step, entity, legal) },
      }
    end

    # Per hex that can be built on: the price for this corporation split into
    # its parts, the tile points, and tile + legal rotations. Not sampled.
    def track_hexes(game, step, entity, legal)
      legal.lay_tile_options(step, entity).map do |hex, tiles|
        cost = game.upgrade_cost(hex.tile, hex, entity, entity)
        {
          hex: hex.id,
          points: step.points_for_hex(hex),
          cost: cost,
          cost_parts: cost_parts(hex.tile, cost),
          tiles: tiles.map { |tile, rotations| { name: tile.name.to_s, color: tile.color.to_s, rotations: rotations } },
        }
      end
    end

    # Terrain cost per upgrade of the hex's tile (label = its terrains), then
    # the discount (track-rights zone, a private's tile discount) as a negative.
    def cost_parts(tile, cost)
      parts = tile.upgrades.select { |u| u.cost.positive? }.map do |u|
        { label: u.terrains.empty? ? "terrain" : u.terrains.join("+"), amount: u.cost }
      end
      base = parts.sum { |p| p[:amount] }
      parts << { label: "discount", amount: cost - base } if cost != base
      parts
    end

    def token_context(game, step, entity, legal)
      tokens = step.available_tokens(entity)
      first = tokens.first
      home = step.is_a?(Engine::Step::HomeToken)
      {
        kind: home ? "home" : "operating",
        price: first && token_price(game, step, first, nil),
        tokens_left: tokens.size,
        cities: legal && legal.token_targets(step, entity).map do |city|
          { hex: city.hex.id, city: city.index, id: city.id, price: token_price(game, step, first, city) }
        end,
      }
    end

    # What placing the token costs: a minor's home token claims a track-rights
    # region and pays for it, every other token its own price.
    def token_price(game, step, token, city)
      owner = token.corporation
      if step.is_a?(Engine::Game::G18OE::Step::HomeToken) && owner.type == :minor
        return city ? game.track_rights_cost(game.region_for_hex(city.hex)) : nil
      end

      token.price
    end

    # One entry per dividend option: `per_share` is what each share gets,
    # `treasury` what the corporation keeps (withheld part plus what its own
    # shares pay), `price` the share price afterwards (nil without one).
    def dividend_context(game, step, entity)
      revenue = step.total_revenue
      {
        revenue: revenue,
        options: step.dividend_options(entity).map do |kind, opt|
          {
            kind: kind.to_s,
            per_share: opt[:per_share],
            treasury: opt[:corporation].to_i + opt[:divs_to_corporation].to_i,
            withheld: opt[:corporation].to_i,
            direction: Array(opt[:share_direction]).map(&:to_s),
            times: Array(opt[:share_times]),
            price: entity.share_price && new_share_price(game, entity, opt),
          }
        end,
      }
    end

    # The market cell a corporation lands on after the moves of a dividend option,
    # walked with the stock market's own movement rules, without moving it.
    def new_share_price(game, entity, opt)
      market = game.stock_market
      coords = entity.share_price.coordinates
      Array(opt[:share_times]).zip(Array(opt[:share_direction])).each do |times, direction|
        times.to_i.times do
          next_coords = market.public_send(direction, entity, coords)
          coords = next_coords if market.share_price(next_coords)&.normal_movement?
        end
      end
      market.share_price(coords)&.price
    end

    def train_context(game, step, entity)
      depot_trains = step.buyable_trains(entity).select(&:from_depot?)
      cheapest = depot_trains.map(&:price).min
      must = step.must_buy_train?(entity) ? true : false
      reserved = step.respond_to?(:reserved_train) ? step.reserved_train : nil
      {
        limit: game.train_limit(entity),
        count: entity.trains.size,
        must_buy: must,
        obligation: { active: game.train_obligation_active?, fulfilled: game.fulfilled_train_obligation?(entity) },
        reserved: reserved && { name: reserved.name, price: reserved.price },
        cheapest_price: cheapest,
        president_may_contribute: step.president_may_contribute?(entity) ? true : false,
        # The president has to chip in when the treasury is short of the cheapest train it may buy.
        shortfall: must && cheapest ? [cheapest - entity.cash, 0].max : 0,
      }
    end

    def safe
      yield
    rescue StandardError
      nil
    end
  end
end
