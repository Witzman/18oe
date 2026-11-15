# frozen_string_literal: true

module Oe
  class Bot
    # What a private, a minor charter or a concession is worth to a bot, in £:
    # the highest price it would pay (#313). Pure heuristic, local, no LLM (rule 7).
    #
    #   valuation = Oe::Bot::Valuation.new(game, rng)
    #   stellung  = Oe::Bot::Valuation::Stellung.from(game, player, step)
    #   valuation.value(company, stellung, Oe::Bot::Valuation::PROFILES[:standard])  # => 135
    #   valuation.affordable?(price, stellung)                                       # reserve kept?
    #
    # Derivation and evidence (rulebook, playbook, map): 18oe-workshop
    # notes/reference/bot-bewertung-313.md. In short:
    #
    #   value = face value                                  (designer packets balance at face, PB 988-1131)
    #         + ability bonus x zone fit                    (map: best zone with a free track-rights chit)
    #         + synergy with what the bot owns              (SYNERGY, draft for the owner's review)
    #         + deny: share of the next player's synergy    (waterfall: if I pass, the next one may buy)
    #         - risk weight x risk x ability bonus          (late / uncertain abilities)
    #   then the quota (#140 rule 1): above 10/N privates or 12/N minors only bargains,
    #   and a minor never above £180 (more goes to the bank, §7.1).
    #
    # Duties, never skipped (also not by 'einfach'): the cash reserve for this
    # player's share of the 18 regional floats (§8.2; #140: capitalise all 30
    # companies, then train phase 3 as early as possible), the quota and the £180 cap. The profile only decides how much risk
    # is priced in and how often an optional check (synergy, zone, deny) is forgotten.
    class Valuation
      # Difficulty levels (#140, owner 2026-11-15; values are an assumption, not yet tuned).
      Profile = Struct.new(:name, :risk_weight, :skip_chance, :deny_weight, :unimplemented_weight,
                           keyword_init: true)
      PROFILES = {
        einfach: Profile.new(name: :einfach, risk_weight: 0.0, skip_chance: 0.3, deny_weight: 0.0, unimplemented_weight: 1.0),
        standard: Profile.new(name: :standard, risk_weight: 0.5, skip_chance: 0.05, deny_weight: 0.3, unimplemented_weight: 1.0),
        schwer: Profile.new(name: :schwer, risk_weight: 1.0, skip_chance: 0.0, deny_weight: 0.5, unimplemented_weight: 1.0),
      }.freeze

      def self.profile(name)
        name = name.to_sym
        name = :standard if name == :mittel
        PROFILES.fetch(name)
      end

      # bonus: £ above face value (estimate from the rule text); risk: 0..1 how
      # uncertain it is to pay off; terrain: map fact the bonus depends on;
      # implemented: the engine has code for it today (see the workshop note, §7).
      Ability = Struct.new(:bonus, :risk, :terrain, :implemented)
      ABILITIES = {
        'RSC' => Ability.new(0, 0.0, nil, true),
        'PeC' => Ability.new(0, 0.0, nil, true),
        'WS' => Ability.new(10, 0.3, nil, false),
        'BBBT' => Ability.new(10, 0.5, nil, false),
        'SHTC' => Ability.new(10, 0.3, :ports, false),
        'CCTC' => Ability.new(10, 0.3, nil, false),
        'WCF' => Ability.new(10, 0.6, nil, true),
        'HMLC' => Ability.new(25, 0.3, :rough, false),
        'BBE' => Ability.new(35, 0.2, :rough, false),
        'SML' => Ability.new(15, 0.5, nil, false),
        'A' => Ability.new(20, 0.6, nil, true),
        'B' => Ability.new(15, 0.2, nil, false),
        'C' => Ability.new(10, 0.3, nil, false),
        'D' => Ability.new(25, 0.2, nil, false),
        'E' => Ability.new(15, 0.3, :water, true),
        'F' => Ability.new(20, 0.3, :rough, true),
        'G' => Ability.new(30, 0.1, nil, true),
        'H' => Ability.new(15, 0.4, :ports, false),
        'J' => Ability.new(20, 0.2, nil, false),
        'K' => Ability.new(35, 0.1, nil, false),
        'L' => Ability.new(20, 0.2, nil, false),
        'M' => Ability.new(20, 0.4, nil, false),
      }.freeze
      NO_ABILITY = Ability.new(0, 0.0, nil, true)

      # Synergy levels between two items (symmetric). DRAFT for the owner's review;
      # reasons per pair in the workshop note, §6.
      SYNERGY = {
        %w[SHTC H] => 3, %w[SHTC E] => 1, %w[WCF H] => 2, %w[WS H] => 1,
        %w[BBBT A] => 2, %w[CCTC L] => 1,
        %w[HMLC F] => 2, %w[HMLC L] => 2,
        %w[BBE G] => 3, %w[BBE B] => 2, %w[BBE F] => 1, %w[BBE K] => 1,
        %w[SML L] => 3, %w[SML C] => 1,
        %w[B G] => 2, %w[F G] => 1, %w[E G] => 1, %w[J M] => 1,
        %w[WS WCF] => 2, %w[CCTC WCF] => 2, %w[BBE HMLC] => 1,
      }.each_with_object({}) { |((a, b), level), h| h[[a, b]] = level; h[[b, a]] = level }.freeze
      SYNERGY_POUNDS = { 1 => 5, 2 => 10, 3 => 20 }.freeze

      PRIVATES_TOTAL = 10
      MINORS_TOTAL = 12
      REGIONALS_TO_FLOAT = 18
      BARGAIN = 0.5 # above the quota an item is only worth this share of its face value

      # The bot's view of the table when valuing an item.
      #   owned: syms of companies the player holds; opponents: [{id:, owned:, cash:}] in
      #   player order starting after the player (first = next to act).
      #   seat: index in player order (0 = first), decides who floats one regional more.
      Stellung = Struct.new(:player_id, :cash, :owned, :opponents, :players, :regionals_floated,
                            :regional_par, :seat, keyword_init: true) do
        def self.from(game, player, step = nil)
          committed = step.respond_to?(:committed_cash) ? step.committed_cash(player).to_i : 0
          order = game.players.rotate(game.players.index(player) || 0)
          new(player_id: player.id,
              cash: player.cash - committed,
              owned: player.companies.map(&:sym),
              opponents: order.drop(1).map { |p| { id: p.id, owned: p.companies.map(&:sym), cash: p.cash } },
              players: game.players.size,
              regionals_floated: game.corporations.count { |c| c.type != :minor && c.floated? && c.owner == player },
              regional_par: Valuation.highest_regional_par(game),
              seat: game.players.index(player) || 0)
        end
      end

      # Highest par a regional can get (60..90 in 18OE); the reserve assumes it,
      # since the par rule (#308) takes 90 wherever the zone has a metropolis (all do).
      def self.highest_regional_par(game)
        prices = game.stock_market.par_prices.map(&:price)
        prices.empty? ? 90 : prices.max
      rescue StandardError
        90
      end

      def initialize(game, rng)
        @game = game
        @rng = rng
      end

      def value(item, stellung, profile = PROFILES[:standard])
        kind = kind(item)
        return item.value if kind == :concession

        ability = ABILITIES.fetch(item.sym, NO_ABILITY)
        bonus = ability.bonus * (ability.implemented ? 1.0 : profile.unimplemented_weight)
        bonus *= zone_fit(ability.terrain) unless forget?(profile)

        worth = item.value + bonus
        worth += synergy(item.sym, stellung.owned) unless forget?(profile)
        worth += profile.deny_weight * synergy(item.sym, stellung.opponents.first&.fetch(:owned, []).to_a) unless forget?(profile)
        worth -= profile.risk_weight * ability.risk * bonus

        # Above the quota only bargains - but not for minors: their price goes into
        # their own treasury (§7.1), a cheap minor is just a minor without a train.
        worth = item.value * BARGAIN if kind == :private && over_quota?(kind, stellung)
        worth = [worth, item.value].min if kind == :minor && over_quota?(kind, stellung)
        worth = [worth, @game.class::MINOR_MAX_TREASURY].min if kind == :minor
        worth.floor
      end

      # Duty: what the player must keep for its share of the 18 regional floats
      # (2 x par each). Whole regionals: cash below 2 x par cannot float one, so a
      # fractional share (4.5 at 4p) would strand money. 18 = N x base + extra; the
      # first `extra` seats in player order plan one regional more (4p: 5, 5, 4, 4).
      def reserve(stellung)
        left = planned_regionals(stellung) - stellung.regionals_floated
        left.positive? ? left * 2 * stellung.regional_par : 0
      end

      def planned_regionals(stellung)
        base, extra = REGIONALS_TO_FLOAT.divmod(stellung.players)
        base + ((stellung.seat || 0) < extra ? 1 : 0)
      end

      def affordable?(price, stellung)
        stellung.cash - price >= reserve(stellung)
      end

      def quota(kind, stellung)
        total = kind == :minor ? MINORS_TOTAL : PRIVATES_TOTAL
        (total.to_f / stellung.players).ceil
      end

      def kind(item)
        return :concession if item.respond_to?(:type) && item.type == :concession
        return :minor if @game.company_becomes_minor?(item)

        :private
      end

      def synergy(sym, owned)
        owned.sum { |other| SYNERGY_POUNDS.fetch(SYNERGY[[sym, other]], 0) }
      end

      # 0..1: how well the best zone still open to a new minor fits the terrain
      # the ability lives on, relative to the best zone on the whole map.
      def zone_fit(terrain)
        return 1.0 unless terrain

        facts = MapFacts.for(@game)
        best = facts.values.map { |f| f[terrain] }.max.to_f
        return 1.0 unless best.positive?

        open = open_zones & facts.keys
        return 1.0 if open.empty? # nothing left to choose: no reason to discount

        open.map { |zone| facts[zone][terrain] }.max / best
      end

      private

      def open_zones
        regions = @game.respond_to?(:minor_available_regions) ? @game.minor_available_regions : nil
        regions ? regions.keys : MapFacts.for(@game).keys
      end

      def over_quota?(kind, stellung)
        owned = stellung.owned.count { |sym| kind(company(sym)) == kind }
        owned >= quota(kind, stellung)
      end

      def company(sym)
        @game.company_by_id(sym)
      end

      def forget?(profile)
        profile.skip_chance.positive? && @rng.rand < profile.skip_chance
      end

      # Per track-rights zone, from the engine's map: rough/mountain and
      # water/river construction cost, port cities. Same for every game of a
      # title, so it is cached per game class.
      module MapFacts
        ROUGH = %i[mountain hill].freeze
        WATER = %i[water river lake].freeze

        module_function

        def for(game)
          @cache ||= {}
          @cache[game.class] ||= compute(game)
        end

        def compute(game)
          klass = game.class
          ports = klass.const_defined?(:PORTS) ? klass::PORTS.keys : []
          klass::NATIONAL_REGION_HEXES.to_h do |zone, coordinates|
            hexes = coordinates.filter_map { |id| game.hex_by_id(id) }
            costs = Hash.new(0)
            hexes.each do |hex|
              hex.tile.upgrades.each do |upgrade|
                costs[:rough] += upgrade.cost if (upgrade.terrains & ROUGH).any?
                costs[:water] += upgrade.cost if (upgrade.terrains & WATER).any? && (upgrade.terrains & ROUGH).empty?
              end
            end
            costs[:ports] = hexes.count { |hex| hex.tile.cities.any? && ports.include?(hex.id) }
            [zone, { rough: costs[:rough], water: costs[:water], ports: costs[:ports] }]
          end
        end
      end
    end
  end
end
