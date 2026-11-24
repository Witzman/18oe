# frozen_string_literal: true

require 'engine'

module Oe
  # Invariants of a game state (#138): rules the engine must never break, checked on any
  # state (catalog entries of #117, or every n-th state of a replayed log). Each check has a
  # name, the rulebook paragraph it comes from (input/18OE_Rulebook_v_1.0.txt) and returns
  # a list of violation texts, empty when the state is fine. Violations are *reported*,
  # never repaired here.
  #
  # A check can be `pending: <issue>`: a violation was found in the engine and is tracked in
  # that issue; the check still runs and shows up in `report`, but does not fail the spec.
  module Invariants
    Check = Struct.new(:name, :rule, :text, :pending, :body, keyword_init: true)
    Violation = Struct.new(:check, :rule, :message, :pending, keyword_init: true) do
      def to_s
        "#{check} (#{rule}): #{message}#{pending ? " [pending ##{pending}]" : ''}"
      end
    end

    # Train supply of the Locomotive Works (rulebook 3.1, setup list; level 7 and 8 from
    # the same list further down), by train name of the base side.
    # Pullmans are depot trains on Chris' engine (#563 Task 5): ten of them.
    TRAIN_SUPPLY = { '2+2' => 30, '3' => 20, '4' => 10, '5' => 8, '6' => 6, '7+7' => 14, '8+8' => 8, 'Pullman' => 10 }.freeze
    # Start of the game: the bank holds this, all of it goes to players/companies over time.
    BANK_CASH = 54_000
    # Added to the bank on the first level 8 purchase (rulebook 13, "remainder cash").
    REMAINDER_CASH = 100_000

    CHECKS = []

    def self.check(name, rule, text, pending: nil, &body)
      CHECKS << Check.new(name: name, rule: rule, text: text, pending: pending, body: body)
    end

    def self.train_base_name(train)
      train.id.sub(/-\d+\z/, '')
    end

    def self.holders(game)
      game.players + game.corporations
    end

    # --- money -----------------------------------------------------------------------

    check(:money_conserved, '3.3 Starting Capital, 13 Ending the Game',
          'bank + players + companies hold exactly the bank\'s starting £54,000 (plus the remainder cash once added)') do |g|
      want = BANK_CASH + (g.instance_variable_get(:@remainder_cash_added) ? REMAINDER_CASH : 0)
      total = g.bank.cash + g.players.sum(&:cash) + g.corporations.sum(&:cash)
      total == want ? [] : ["total #{total}, expected #{want}"]
    end

    check(:no_negative_cash, '11.6 Buy Trains (price at most the treasury), 13 Ending the Game',
          'no player or company has negative cash; the bank only after it broke') do |g|
      out = holders(g).select { |h| h.cash.negative? }.map { |h| "#{h.name} has #{h.cash}" }
      out << "bank has #{g.bank.cash} without being broken" if g.bank.cash.negative? && !g.bank.broken?
      g.finished ? [] : out
    end

    # --- certificates and shares -------------------------------------------------------

    check(:shares_total_100, '4.2 Share Limits, 2.5 Certificates',
          'the certificates of each company add up to exactly 100 %') do |g|
      g.shares.group_by(&:corporation).filter_map do |corp, shares|
        next if corp.closed?

        sum = shares.sum(&:percent)
        "#{corp.name} certificates add up to #{sum} %" unless sum == 100
      end
    end

    check(:shares_single_holder, '2.5 Certificates',
          'every certificate lies in exactly one portfolio, and that portfolio knows its owner') do |g|
      all = g.shares
      out = all.group_by(&:object_id).select { |_, v| v.size > 1 }.map { |_, v| "#{v.first.id} held #{v.size} times" }
      all.each do |share|
        owner = share.owner
        out << "#{share.id} has no owner" if owner.nil?
        out << "#{share.id} not in the portfolio of #{owner.name}" if owner && !owner.shares.include?(share)
      end
      out
    end

    check(:president_holds_presidency, '10.3 Change of Presidency, 2.5 Certificates',
          'an open company has exactly one president\'s certificate, held by the company\'s president') do |g|
      g.corporations.filter_map do |corp|
        next if corp.closed? || !corp.ipoed

        pres = g.shares.select { |s| s.corporation == corp && s.president }
        next "#{corp.name} has #{pres.size} president certificates" unless pres.size == 1
        next unless corp.owner&.player? && pres.first.owner != corp.owner && corp.owner.percent_of(corp).zero?

        "#{corp.name} president #{corp.owner.name} holds none of its stock"
      end
    end

    # #426: rule 3.3 allows a player over the limit (a presidency swap caused by another player's purchase,
    # a merge) until their first opportunity in a stock round; so a waiting player is not checked, the
    # player to act is: over the limit they may only sell or reduce their face-up privates.
    check(:certificate_limit, '4.1 Certificate Limits, 3.3 (correct at the first opportunity in a stock round)',
          'a player over the certificate limit may, at their turn in a stock round, only sell or reduce privates') do |g|
      next [] if g.finished || !g.round.stock?

      player = g.round.current_entity
      step = g.round.active_step
      next [] unless player&.player? && step.is_a?(Engine::Step::BuySellParShares)
      next [] if g.num_certs(player) <= g.cert_limit(player)

      others = step.actions(player) - %w[sell_shares choose]
      next [] if others.empty?

      ["#{player.name} holds #{g.num_certs(player)} certificates, limit #{g.cert_limit(player)}, " \
       "and may #{others.join(', ')}"]
    end

    check(:reserved_shares_consistent, '8.4 Reserved Shares (initial stock round, more than two players)',
          'a reserved share is a secondary share of a regional, at most one per player, only in the initial stock round') do |g|
      list = g.instance_variable_get(:@reserved_shares) || []
      next [] if list.empty?

      out = []
      out << 'a share is reserved outside the initial stock round' unless g.round.stock? && g.turn == 1
      out << 'a share is reserved in a game of two players' if g.players.size <= 2
      list.each do |share|
        corp = share.corporation
        out << "#{share.id} of #{corp.name} is the president's certificate" if share.president
        out << "#{corp.name} is reserved but no longer a regional" unless corp.type == :regional
      end
      owners = list.map { |s| s.corporation.owner }
      out << 'a player reserved more than one share' if owners.uniq.size != owners.size
      out << 'a share is reserved twice' if list.map(&:object_id).uniq.size != list.size
      out
    end

    # --- trains ------------------------------------------------------------------------

    check(:train_supply, '3.1 Setup (Locomotive Works), 5 Game Phases',
          'train counts per level equal the rulebook supply, no train twice or lost') do |g|
      trains = g.depot.trains
      out = trains.group_by { |t| train_base_name(t) }.transform_values(&:size).reject { |k, v| TRAIN_SUPPLY[k] == v }
                  .map { |k, v| "#{v} trains of #{k}, rulebook has #{TRAIN_SUPPLY[k].inspect}" }
      out << "#{TRAIN_SUPPLY.keys - trains.map { |t| train_base_name(t) }} missing" if (TRAIN_SUPPLY.keys - trains.map { |t| train_base_name(t) }).any?
      out << "a train object appears twice" if trains.map(&:object_id).uniq.size != trains.size
      trains.each do |t|
        owner = t.owner
        # A rusted train has left the game: the engine clears its owner (5.2 Train Phases).
        out << "#{t.id} has no owner" if owner.nil? && !t.rusted
        out << "#{t.id} not in the trains of #{owner.name}" if owner && owner != g.depot && !owner.trains.include?(t)
      end
      out
    end

    check(:train_limit, '11.6 Buy Trains, 5.2 Train Phases (excess goes in the discard step)',
          'no company holds more trains than the phase allows, unless a discard step is pending') do |g|
      next [] if g.finished
      # 9.4: the national formation window (FormNational) comes before the discard step, because a new
      # national keeps even the rusting trains; a major over the new limit is only due once that window is over.
      next [] if g.round.active_step.class.name.to_s.match?(/Discard|FormNational/)

      g.corporations.filter_map do |corp|
        next unless corp.floated? && !corp.closed?

        limit = g.train_limit(corp)
        count = corp.trains.count { |t| !t.rusted }
        "#{corp.name} owns #{count} trains, limit #{limit}" if count > limit
      end
    end

    # --- map ---------------------------------------------------------------------------

    check(:tokens_consistent, '2.6 Tokens, 11.3 Tokens',
          'no token on the map twice, every used token is on a city that holds it, no city above its slots') do |g|
      out = []
      seen = {}
      g.hexes.each do |hex|
        hex.tile.cities.each do |city|
          placed = city.tokens.compact
          out << "#{hex.id}: #{placed.size} tokens in #{city.slots} slots" if placed.size > city.slots
          out << "#{hex.id}: a company twice in one city" if placed.map(&:corporation).uniq.size != placed.size
          placed.each do |tok|
            out << "token of #{tok.corporation&.name} on the map twice (#{hex.id})" if seen[tok.object_id]
            seen[tok.object_id] = true
          end
        end
      end
      g.corporations.each do |corp|
        used = corp.tokens.select(&:used)
        out << "#{corp.name}: a used token is not on the map" unless used.all? { |t| seen[t.object_id] }
        out << "#{corp.name}: token on the map that is not marked used" if corp.tokens.any? { |t| seen[t.object_id] && !t.used }
      end
      out
    end

    check(:tiles_consistent, '2.3 Track Tiles',
          'each tile lies on at most one hex, every hex tile knows its hex, and tile counts per name stay within the supply') do |g|
      out = []
      on_map = g.hexes.map(&:tile)
      out << 'a tile lies on two hexes' if on_map.map(&:object_id).uniq.size != on_map.size
      laid = on_map.reject(&:preprinted)
      laid.each do |tile|
        out << "tile #{tile.id} claims #{tile.hex&.id.inspect}, lies on another hex" if tile.hex && g.hex_by_id(tile.hex.id).tile != tile
        out << "tile #{tile.id} is not a tile of the game" unless g.tile_by_id(tile.id).equal?(tile)
      end
      laid.reject(&:unlimited).group_by(&:name).each do |name, tiles|
        have = g.class::TILES[name]
        want = have.is_a?(Hash) ? have['count'] : have
        out << "#{tiles.size} tiles named #{name} laid, supply is #{want}" if want && tiles.size > want
      end
      out
    end

    # --- stock market ------------------------------------------------------------------

    check(:stock_market_positions, '4.3 Entering the Stock Market, 4.4 Share Value Marker Movement',
          'a share price lies on the market, the company is in its cell, and an open company was parred at a value of the par list') do |g|
      out = []
      market = g.stock_market.market
      g.corporations.each do |corp|
        price = corp.share_price
        next if corp.closed?
        unless price
          # a minor floats without a par (§9.1; Chris' engine since upstream 49c770035, #600)
          out << "#{corp.name} is floated without a share price" if corp.floated? && corp.type != :minor
          next
        end
        row, col = price.coordinates
        out << "#{corp.name} price coordinates #{price.coordinates.inspect} off the market" if market[row].nil? || market[row][col].nil?
        out << "#{corp.name} not in its market cell" if market[row] && market[row][col] && !market[row][col].corporations.include?(corp)
        # par_price answers the current price here (always_market_price); the par is original_par_price.
        par = corp.original_par_price
        pars = g.stock_market.par_prices.map(&:price)
        out << "#{corp.name} par #{par.price} is not a par value #{pars}" if par && !pars.include?(par.price)
        out << "#{corp.name} is open without a par value" if corp.ipoed && par.nil?
      end
      out
    end

    # --- running ------------------------------------------------------------------------

    def self.run(game, only: nil)
      CHECKS.flat_map do |c|
        next [] if only && !Array(only).include?(c.name)

        c.body.call(game).map do |msg|
          Violation.new(check: c.name, rule: c.rule, message: msg, pending: c.pending)
        end
      end
    end

    # Violations that still count (not tracked by a pending issue).
    def self.failures(violations)
      violations.reject(&:pending)
    end

    # Replays an action log (as bin/playthrough writes it) and runs the checks after every
    # `every`-th action, up to `upto` actions. Returns [[position, violation], ...].
    def self.check_log(file, every: 25, upto: nil, only: nil)
      actions = file['actions_log']
      actions = actions.first(upto) if upto
      game = Engine::Game::G18OE::Game.new(("A".."Z").first(file['players']), id: file['seed'], seed: file['seed'])
      found = []
      actions.each_with_index do |action, index|
        game.process_action(action)
        raise "engine rejected action #{index + 1}: #{game.exception.message}" if game.exception

        found.concat(run(game, only: only).map { |v| [index + 1, v] }) if ((index + 1) % every).zero? || index + 1 == actions.size
      end
      found
    end

    # A table of checks with their rule paragraph and status, for `bin/fixture-catalog invariants`.
    def self.report(violations = [])
      names = violations.map(&:check).tally
      CHECKS.map do |c|
        status = if c.pending then "pending ##{c.pending}"
                 elsif names[c.name] then "#{names[c.name]} violation(s)"
                 else 'ok'
                 end
        format('%-26s %-14s §%s — %s', c.name, status, c.rule, c.text)
      end.join("\n")
    end
  end
end
