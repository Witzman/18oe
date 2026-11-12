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
        bank: { cash: game.bank.cash },
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
        },
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
      }
    end

    # Percent per holder; the sum over all holders is 100 for an ipoed corporation.
    def share_holders(game, corp)
      pool = game.share_pool
      corp.share_holders.filter_map do |holder, percent|
        next if percent.to_i.zero?

        owner =
          if holder.respond_to?(:player?) && holder.player? then holder.id
          elsif holder.equal?(pool) then "market"
          elsif holder.equal?(corp.ipo_owner) then "ipo"
          else holder.respond_to?(:id) ? holder.id.to_s : holder.class.name
          end
        [owner, percent]
      end.sort_by { |owner, _| owner }.map { |owner, percent| { holder: owner, percent: percent } }
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

      { revenue: info.revenue, dividend: info.dividend_kind&.to_s }
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
      if mine && with_actions
        list = Oe::LegalActions.new(game, limit: limit, rng: Random.new(0)).call.map { |a| a.to_h.reject { |k, _| %w[id created_at user].include?(k) } }
      end
      {
        step: step && step.class.name.split("::").last,
        types: step ? Array(step.current_actions).map(&:to_s) : [],
        viewer_to_act: mine ? true : false,
        actions: list,
      }
    end

    def safe
      yield
    rescue StandardError
      nil
    end
  end
end
