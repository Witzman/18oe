# frozen_string_literal: true

require_relative 'meta'
require_relative 'entities'
require_relative 'map'
require_relative 'stock_market'
require_relative 'graph'
require_relative '../base'
require_relative 'round/consolidation'
require_relative 'round/concession'
require_relative 'golden_bell'
require_relative 'sea'
require_relative 'step/consolidate'
require_relative 'step/hochberg_token'
require_relative 'green_junction'
require_relative 'right_of_way'
require_relative 'step/home_hex_consent'
require_relative 'step/special_track'
require_relative 'step/golden_bell_order'
require_relative 'step/bankrupt'
require_relative 'step/convert_to_national'
require_relative 'step/discard_train'
require_relative 'step/merge_discard_train'
require_relative 'step/merge_minor'
require_relative 'step/merge_offer'
require_relative 'step/merge_token'
require_relative 'step/concession'
require_relative 'step/reserve_share'
require_relative 'step/orient_express_bonus'
require_relative 'step/route'
require_relative 'step/special_token'

module Engine
  module Game
    module G18OE
      class Game < Game::Base
        include_meta(G18OE::Meta)
        include G18OE::Entities
        include G18OE::Map
        include G18OE::GoldenBell
        include G18OE::GreenJunction
        include G18OE::RightOfWay
        include G18OE::Sea
        attr_accessor :minor_regional_order, :minor_available_regions, :minor_floated_regions,
                      :consolidation_triggered, :consolidation_complete
        attr_reader :concessions, :concession_owners, :merged_minors, :wcf_placeholder, :national_formation,
                    :hochberg_hex,
                    :bbe_token_hexes

        FERRY_COLOR = '#0047AB'
        PATRONAGE_DRAWS = [{ group: :pink, count: 3 }, { group: :yellow, count: 3 },
                           { group: :white, count: 3 }, { group: :green, count: 8 }].freeze

        MARKET = [
          ['', '110', '120C', '135', '150', '165', '180', '200', '225', '250', '280', '310', '350', '390', '440', '490', '550'],
          %w[90p 100 110C 120 135 150 165 180 200 225 250 280 310 350 390 440 490],
          %w[80p 90 100C 110 120 135 150 165 180 200 225 250 280 310],
          %w[75p 80 90C 100 110 120 135 150 165 180 200],
          %w[70p 75 80C 90 100 110 120 135 150],
          %w[65p 70 75C 80 90 100 110],
          %w[60p 65 70 75 80],
          %w[50 60 65 70],
        ].freeze
        CERT_LIMIT = { 2 => 99, 3 => 48, 4 => 36, 5 => 29, 6 => 24, 7 => 20 }.freeze
        # Standard game: £5,400 total / num_players, rounded up to nearest £5.
        # 2-player variant uses without-concessions formula (£5,200 / 2 = £2,600).
        STARTING_CASH = { 2 => 2600, 3 => 1800, 4 => 1350, 5 => 1080, 6 => 900, 7 => 775 }.freeze
        STARTING_CASH_NO_CONCESSIONS = { 2 => 2600, 3 => 1735, 4 => 1300, 5 => 1040, 6 => 870, 7 => 745 }.freeze
        BANK_CASH = 54_000
        CURRENCY_FORMAT_STR = '£%s'
        CAPITALIZATION = :incremental
        SELL_BUY_ORDER = :sell_buy
        MUST_SELL_IN_BLOCKS = false
        HOME_TOKEN_TIMING = :float
        TILE_RESERVATION_BLOCKS_OTHERS = :always
        TILE_UPGRADES_MUST_USE_MAX_EXITS = [:cities].freeze
        # bank-break ends current OR; first level-8 purchase ends after one more full OR set
        GAME_END_CHECK = { bank: :current_or, final_phase: :one_more_full_or_set }.freeze
        # Physical game includes 20×£5,000 notes set aside at setup; injected when first level-8 bought
        REMAINDER_CASH = 100_000
        ABANDONED_MINOR_PRICE = 60

        STOCKMARKET_COLORS = {
          par: :blue,
          convert_range: :red,
        }.freeze

        EVENTS_TEXT = Base::EVENTS_TEXT.merge(
          'level_8_available' => ['Level 8 Trains Available', 'Level 8 trains may be bought'],
          'consolidation_triggered' => [
            'Consolidation Round',
            'Consolidation round follows at end of current OR set; minors and regionals must merge or be abandoned',
          ],
          'remainder_cash_added' => [
            'Remainder Cash Added',
            '£100,000 remainder cash injected into bank; game ends after one more full OR set',
          ]
        ).freeze

        MARKET_TEXT = {
          par: 'Regional par values',
          convert_range: 'Major par values',
        }.freeze

        PHASES = [
          {
            name: '2',
            train_limit: { minor: 2, regional: 2, major: 4 },
            tiles: [:yellow],
            operating_rounds: 2,
            status: ['train_obligation'],
          },
          {
            name: '3',
            on: '3',
            train_limit: { minor: 2, regional: 2, major: 4 },
            tiles: %i[yellow green],
            operating_rounds: 2,
            status: ['train_obligation'],
          },
          {
            name: '4',
            on: '4',
            train_limit: { minor: 1, regional: 1, major: 3, national: 4 },
            tiles: %i[yellow green],
            operating_rounds: 2,
            status: [],
          },
          {
            name: '5',
            on: '5',
            train_limit: { minor: 1, regional: 1, major: 3, national: 4 },
            tiles: %i[yellow green brown],
            operating_rounds: 2,
            status: [],
          },
          {
            name: '6',
            on: '6',
            train_limit: { major: 2, national: 3 },
            tiles: %i[yellow green brown],
            operating_rounds: 2,
            status: [],
          },
          {
            name: '7',
            on: '7+7',
            train_limit: { major: 2, national: 3 },
            tiles: %i[yellow green brown gray],
            operating_rounds: 2,
            status: [],
          },
          {
            name: '8',
            on: '8+8',
            train_limit: { major: 2, national: 3 },
            tiles: %i[yellow green brown gray],
            operating_rounds: 2,
            status: [],
          },
        ].freeze

        TRAINS = [
          # Level 2 — yellow; rusts when first Level 4 train is bought
          {
            name: '2+2',
            distance: [{ 'nodes' => ['town'], 'pay' => 2, 'visit' => 99 },
                       { 'nodes' => %w[city offboard town], 'pay' => 2, 'visit' => 2 }],
            price: 100,
            rusts_on: '4',
            num: 30,
          },
          # Level 3 — green double-sided (3 / 3+3); rust at Level 6
          {
            name: '3',
            distance: [{ 'nodes' => ['town'], 'pay' => 0, 'visit' => 99 },
                       { 'nodes' => %w[city offboard town], 'pay' => 3, 'visit' => 3 }],
            price: 200,
            rusts_on: '6',
            variants: [{
              name: '3+3',
              distance: [{ 'nodes' => ['town'], 'pay' => 3, 'visit' => 99 },
                         { 'nodes' => %w[city offboard town], 'pay' => 3, 'visit' => 3 }],
              price: 225,
              rusts_on: '6',
            }],
            num: 20,
          },
          # Level 4 — green double-sided (4 / 4+4); rust at Level 8
          {
            name: '4',
            distance: [{ 'nodes' => ['town'], 'pay' => 0, 'visit' => 99 },
                       { 'nodes' => %w[city offboard town], 'pay' => 4, 'visit' => 4 }],
            price: 300,
            rusts_on: '8+8',
            variants: [{
              name: '4+4',
              distance: [{ 'nodes' => ['town'], 'pay' => 4, 'visit' => 99 },
                         { 'nodes' => %w[city offboard town], 'pay' => 4, 'visit' => 4 }],
              price: 350,
              rusts_on: '8+8',
            }],
            num: 10,
          },
          # Level 5 — brown double-sided (5 / 5+5); permanent
          {
            name: '5',
            distance: [{ 'nodes' => ['town'], 'pay' => 0, 'visit' => 99 },
                       { 'nodes' => %w[city offboard town], 'pay' => 5, 'visit' => 5 }],
            price: 400,
            variants: [{
              name: '5+5',
              distance: [{ 'nodes' => ['town'], 'pay' => 5, 'visit' => 99 },
                         { 'nodes' => %w[city offboard town], 'pay' => 5, 'visit' => 5 }],
              price: 475,
            }],
            num: 8,
            events: [{ 'type' => 'consolidation_triggered' }],
          },
          # Level 6 — brown double-sided (6 / 6+6); permanent
          {
            name: '6',
            distance: [{ 'nodes' => ['town'], 'pay' => 0, 'visit' => 99 },
                       { 'nodes' => %w[city offboard town], 'pay' => 6, 'visit' => 6 }],
            price: 525,
            variants: [{
              name: '6+6',
              distance: [{ 'nodes' => ['town'], 'pay' => 6, 'visit' => 99 },
                         { 'nodes' => %w[city offboard town], 'pay' => 6, 'visit' => 6 }],
              price: 600,
            }],
            num: 6,
          },
          # Level 7 — gray double-sided (7+7 / 4D); permanent
          # NOTE: Level 8 trains become available only after the 4th Level 7 purchase
          {
            name: '7+7',
            distance: [{ 'nodes' => ['town'], 'pay' => 7, 'visit' => 99 },
                       { 'nodes' => %w[city offboard town], 'pay' => 7, 'visit' => 7 }],
            price: 750,
            variants: [{
              name: '4D',
              distance: [{ 'nodes' => ['town'], 'pay' => 0, 'visit' => 99 },
                         { 'nodes' => %w[city offboard], 'pay' => 4, 'visit' => 4 }],
              multiplier: 2,
              price: 850,
            }],
            num: 14,
            events: [{ 'type' => 'level_8_available', 'when' => 4 }],
          },
          # Level 8 — gray double-sided (8+8 / 5D); permanent
          # NOTE: purchase of the FIRST level-8 triggers game end
          {
            name: '8+8',
            distance: [{ 'nodes' => ['town'], 'pay' => 8, 'visit' => 99 },
                       { 'nodes' => %w[city offboard town], 'pay' => 8, 'visit' => 8 }],
            price: 900,
            variants: [{
              name: '5D',
              distance: [{ 'nodes' => ['town'], 'pay' => 0, 'visit' => 99 },
                         { 'nodes' => %w[city offboard], 'pay' => 5, 'visit' => 5 }],
              multiplier: 2,
              price: 1000,
            }],
            num: 8,
            available_on: '7',
            events: [{ 'type' => 'remainder_cash_added' }],
          },
        ].freeze

        # 2 chits per zone; 16 total for 12 minors.
        # Asterisked zones (UK/PHS/FR): 6 chits combined but capped at 4 selections —
        # when the 4th is taken the remaining chits for those zones are removed from play.
        MINOR_TRACK_RIGHTS_CHITS = {
          'UK' => 2,
          'PHS' => 2,
          'FR' => 2,
          'AH' => 2,
          'IT' => 2,
          'SP' => 2,
          'SC' => 2,
          'RU' => 2,
        }.freeze
        ASTERISKED_ZONES = %w[UK PHS FR].freeze
        ASTERISKED_ZONES_CAP = 4

        ZONE_DISCOUNT_ZONES         = %w[SP IT SC RU].freeze
        ZONE_DISCOUNT_RATE          = 0.2 # 20% §11.1.5
        ZONE_TERRAIN_DISCOUNT_RATE  = 0.5 # 50% §11.1.5; E/F augment zone discount to this rate
        TILE_POINT_BUDGET = { minor: 3, regional: 3, major: 6, national: 9 }.freeze
        MINOR_MAX_TREASURY = 180
        # §11.6.4: the president of a major that must buy a train pays the difference from his own cash
        # and may not sell shares to do it; a major that cannot pay becomes a national (Step::Bankrupt).
        EBUY_CAN_SELL_SHARES = false
        EF_TERRAIN_COST_FACTOR      = [67, 100].freeze # §15.5/15.6: x 0.67, rounded down
        EF_TERRAIN_AUGMENT          = { 'E' => %i[water river lake], 'F' => %i[mountain hill] }.freeze

        CORPORATIONS_TRACK_RIGHTS = {
          # United Kingdom
          'LNWR' => 'UK',
          'GWR' => 'UK',
          'GSWR' => 'UK',
          # France / Belgium
          'PLM' => 'FR',
          'MIDI' => 'FR',
          'OU' => 'FR',
          'BEL' => 'FR',
          # Prussia / Holland / Switzerland
          'BHB' => 'PHS',
          'POB' => 'PHS',
          'KSS' => 'PHS',
          'KBS' => 'PHS',
          # Austria-Hungary
          'SB' => 'AH',
          'MAV' => 'AH',
          # Italy
          'SFAI' => 'IT',
          'SFR' => 'IT',
          # Spain / Portugal
          'CHN' => 'SP',
          'MZA' => 'SP',
          'RCP' => 'SP',
          # Russia
          'MSP' => 'RU',
          'MKV' => 'RU',
          'LRZD' => 'RU',
          'WW' => 'RU',
          # Scandinavia
          'DSJ' => 'SC',
          'BJV' => 'SC',
        }.freeze

        NATIONAL_REGION_HEXES = {
          # United Kingdom / Ireland
          'UK' => %w[D25 E24 E26 E28 F23 F25 F27 F29 G16 G18 G20 G24 G26 G28
                     H15 H17 H19 H21 H25 H27 H29 I14 I16 I18 I20 I26 I28
                     J13 J15 J17 J19 J23 J25 J27 J29 K22 K24 K26 K28 K30
                     L23 L25 L27 L29 L31 M22 M24 M26 M28 M30],
          # Scandinavia (Sweden / Norway / Denmark)
          'SC' => %w[A42 A44 A46 A48 A50 A52 A54 A56 B41 B43 B45 B47 B49 B51 B53 B55 B57
                     C42 C44 C46 C48 C50 C52 C54 C56 C58 D41 D43 D45 D47 D49 D51 D53 D55 D57
                     E42 E44 E48 E50 E52 E54 E56 E58 F49 F51 F53 F55
                     G44 G46 G50 G52 G54 G56 H43 H45 H47 H51 H53 H55 I44 I46 I48 I50 I52 J49],
          # France / Belgium
          'FR' => %w[N31 N33 N35 N37 O24 O28 O30 O32 O34 O36 O38
                     P19 P21 P23 P25 P27 P29 P31 P33 P35 P37
                     Q20 Q22 Q24 Q26 Q28 Q30 Q32 Q34 Q36 Q38
                     R23 R25 R27 R29 R31 R33 R35 R37 R39
                     S24 S26 S28 S30 S32 S34 S36 S38 T23 T25 T27 T29 T31 T33 T35 T37
                     U22 U24 U26 U28 U30 U32 U34 U36 U38
                     V21 V23 V25 V27 V29 V31 V33 V35 V37
                     W22 W24 W26 W28 W30 W32 W34 W36 W38
                     X25 X27 X29 X33 X35 X37 Y28 Z41 AF25],
          # Prussia / Holland / Switzerland
          'PHS' => %w[I64 J45 J47 J63 J65 K40 K42 K44 K46 K48 K50 K54 K56 K58 K60 K62 K64
                      L37 L39 L41 L43 L45 L47 L49 L51 L53 L55 L57 L59 L61
                      M34 M36 M38 M40 M42 M44 M46 M48 M50 M52 M54 M56 M58
                      N37 N39 N41 N43 N45 N47 N49 N51 N53 N55 N57
                      O38 O40 O42 O44 O46 O48 O50 O52 O54 O56 O58
                      P39 P41 P43 P45 P47 P49 Q38 Q40 Q42 Q44 Q46 Q48 Q50
                      R39 R41 R43 R45 R47 R49 R51 S38 S40 S42 S44 S46 S48
                      T37 T39 T41 T43 U38 U40 U42],
          # Austria-Hungary
          'AH' => %w[O52 O54 P49 P51 P53 P55 P57 P59 P61 P63 P65 P67 P69 P71 P73
                     Q50 Q52 Q54 Q56 Q58 Q60 Q62 Q64 Q66 Q68 Q70 Q72 Q74
                     R51 R53 R55 R57 R59 R61 R63 R65 R67 R69 R71 R73
                     S44 S46 S48 S50 S52 S54 S56 S58 S60 S62 S64 S66 S68 S70 S72 S74
                     T45 T47 T49 T51 T53 T55 T57 T59 T61 T63 T65 T67 T69 T71 T73 T75
                     U50 U52 U54 U56 U58 U60 U62 U64 U66 U68 U70 U72 U74
                     V51 V53 V55 V57 V59 V61 V63 V65 V67 V69
                     W54 W56 W58 W60 X55 X57 X59 X61 Y56 Y58 Y60 Y62],
          # Italy
          'IT' => %w[U38 U40 U42 U44 U46 U48 V37 V39 V41 V43 V45 V47
                     W38 W40 W42 W44 W46 W48 X43 X45 X47 X49 Y44 Y46 Y48 Y50
                     Z45 Z47 Z49 Z51 AA48 AA50 AA52 AA54
                     AB39 AB41 AB51 AB53 AB55 AB57 AC38 AC40 AC54 AC56 AC58
                     AD39 AD55 AE52 AF49 AF51 AF53 AG40 AG50 AG52],
          # Spain / Portugal
          'SP' => %w[U6 U8 U10 U12 V5 V7 V9 V11 V13 V15 V17 V19
                     W6 W8 W10 W12 W14 W16 W18 W20 W22
                     X5 X7 X9 X11 X13 X15 X17 X19 X21 X23 X25
                     Y2 Y4 Y6 Y8 Y10 Y12 Y14 Y16 Y18 Y20 Y22 Y24 Y26 Y28
                     Z1 Z3 Z5 Z7 Z9 Z11 Z13 Z15 Z17 Z19 Z21 Z23 Z25 Z27
                     AA2 AA4 AA6 AA8 AA10 AA12 AA14 AA16 AA18 AA20 AA22
                     AB1 AB3 AB5 AB7 AB9 AB11 AB13 AB15 AB17 AB19
                     AC6 AC8 AC10 AC12 AC14 AC16 AC18 AC20
                     AD1 AD5 AD7 AD9 AD11 AD13 AD15 AD17 AF5 AF11],
          # Russia
          'RU' => %w[A64 A66 A68 A70 A72 A74 B63 B65 B67 B69 B71 B73 B75 B77 B79 B81 B83
                     C64 C66 C72 C74 C76 C78 C80 C82 D67 D69 D71 D73 D75 D77 D79 D81 D83 D85
                     E66 E68 E70 E72 E74 E76 E78 E80 E82 E84 E86
                     F69 F71 F73 F75 F77 F79 F81 F83 F85 F87
                     G64 G66 G68 G70 G72 G74 G76 G78 G80 G82 G84 G86 G88
                     H63 H65 H67 H69 H71 H73 H75 H77 H79 H81 H83 H85 H87
                     I64 I66 I68 I70 I72 I74 I76 I78 I80 I82 I84 I86
                     J67 J69 J71 J73 J75 J77 J79 J81 J83 J85 J87
                     K64 K66 K68 K70 K72 K74 K76 K78 K80 K82 K84 K86
                     L61 L63 L65 L67 L69 L71 L73 L75 L77 L79 L81 L83 L85 L87
                     M58 M60 M62 M64 M66 M68 M70 M72 M74 M76 M78 M80 M82 M84 M86
                     N59 N61 N63 N65 N67 N69 N71 N73 N75 N77 N79 N81 N83 N85 N87
                     O58 O60 O62 O64 O66 O68 O70 O72 O74 O76 O78 O80 O82 O84 O86
                     P73 P75 P77 P79 P81 P83 P85 P87 Q74 Q76 Q78 Q80 Q82 Q84 Q86
                     R75 R77 R79 R81 R83 R85 R87 S76 S78 S80 S82 S84 S86 S88 T79 T81 T87 U80],
        }.freeze

        # Cities that sit on a national-zone border hex (hex listed in two zones).
        # All other cities belong unambiguously to one zone; only these need an explicit override.
        CITY_NATIONAL_ZONE = {
          'Q38' => 'FR',  # Nancy   — FR/PHS border hex
          'O52' => 'PHS', # Dresden — PHS/AH border hex
          'S76' => 'BRS',
        }.freeze

        # Cities excluded from minor home-token placement regardless of zone membership.
        # These are Balkan / Ottoman / south-east European cities outside the concession
        # railroad system. Most are already outside all zone hex lists; S76 (Jassy) is the
        # only one currently inside a zone (RU) that requires active filtering.
        # AA82 (Constantinople) is also excluded via metropolis_hex? but listed here for clarity.
        MINOR_EXCLUDED_HOME_CITIES = %w[
          S76 W64 W74 Y70
          AA62 AB69 AD79 AE72 AA82
        ].freeze

        TRACK_RIGHTS_COST = {
          'UK' => 40,
          'PHS' => 40,
          'FR' => 20,
          'AH' => 20,
          'IT' => 10,
          'SP' => 10,
          'RU' => 10,
          'SC' => 10,
        }.freeze

        MAX_FLOATED_REGIONALS = 18
        ORIENT_EXPRESS_ORIGINS = %w[Paris London Berlin Madrid Sankt-Peterburg].freeze
        ORIENT_EXPRESS_DESTINATIONS = %w[Constantinople].freeze
        ORIENT_EXPRESS_BONUS = { '2' => 30, '3' => 30, '4' => 30, '5' => 60, '6' => 60, '7' => 100, '8' => 100 }.freeze
        CONVERSION_NEW_SHARES = 6
        MAJOR_MAX_OWNERSHIP_PERCENT = 60
        TWO_PLAYER_MAJOR_MAX_OWNERSHIP_PERCENT = 70
        EXTENDED_FINAL_OPERATING_ROUNDS = 3
        # §9.4: nationals may form when these Train Phases begin (the level 2, 3, 4 trains rust).
        NATIONAL_FORMATION_PHASES = %w[4 6 8].freeze

        def setup
          super
          @minor_regional_order = []
          @minor_available_regions = self.class::MINOR_TRACK_RIGHTS_CHITS.transform_values(&:itself)
          @minor_asterisked_selected = 0
          @minor_floated_regions = {}
          @merged_minors = Hash.new { |hash, corporation| hash[corporation] = [] }
          @removed_regional_zones = []
          @orient_express_markers = []
          @last_payouts = {}
          @concessions = companies.select { |company| concession?(company) }
          @fulfilled_train_obligation = Set.new
          @first_or_complete = false
          @reserved_shares = []
          @face_down_privates = []

          corporations.each do |corp|
            corp.par_via_exchange = companies.find { |c| c.sym == corp.id } if corp.type == :minor
          end

          setup_patronage_tiles!
          setup_wcf_placeholder!
          @minor_g_ability = corporation_by_id('G')&.abilities&.first
          setup_bbe_ability!
          # §15.2: the ability object travels with the charter into the major on a merge
          @minor_b_ability = corporation_by_id('B')&.abilities&.first
          # §15.5/§15.6: the ability objects travel with the charter into the major on a merge
          @ef_abilities = %w[E F].to_h { |id| [id, corporation_by_id(id)&.abilities&.first] }
          # §15.4: Minor D's token
          setup_green_junction!
        end

        def setup_wcf_placeholder!
          @wcf_placeholder = Engine::Token.new(nil, price: 0, logo: '/logos/18_oe/wcf_reserved.svg', type: :neutral)
          lille_city.exchange_token(@wcf_placeholder, extra_slot: true)
        end

        def setup_patronage_tiles!
          drawn = self.class::PATRONAGE_DRAWS.flat_map do |draw|
            candidates = self.class::PATRONAGE_TILES.select do |_hex_id, data|
              data[:group] == draw[:group] && (draw[:zone].nil? || data[:zone] == draw[:zone])
            end
            candidates.keys.sort_by { rand }.take(draw[:count])
          end
          drawn.each { |hex_id| place_patronage_tile!(hex_id) }

          entries = drawn.map do |id|
            "#{hex_by_id(id).location_name} (#{id}) #{self.class::PATRONAGE_TILES[id][:payouts].values.join('/')}"
          end
          @log << "Patronage tiles: #{entries.join(', ')}"
        end

        def place_patronage_tile!(hex_id)
          hex_by_id(hex_id).tile.patronage = self.class::PATRONAGE_TILES[hex_id][:payouts]
        end

        def patronage_color
          @phase.tiles.last
        end

        def remove_patronage!(hex)
          payouts = hex.tile.patronage
          hex.tile.patronage = nil
          payouts
        end

        def fulfill_patronage!(entity, hex)
          payouts = remove_patronage!(hex)
          return unless payouts

          amount = payouts[patronage_color]
          @bank.spend(amount, entity)
          @log << "#{entity.name} fulfills the #{hex.location_name} patronage tile and receives #{format_currency(amount)}"
        end

        def medium_start?
          @optional_rules.include?(:medium_start)
        end

        def concessions?
          !medium_start? && players.size > 2
        end

        def concession?(company)
          company.type == :concession
        end

        def init_starting_cash(players, bank)
          cash = medium_start? ? self.class::STARTING_CASH_NO_CONCESSIONS : self.class::STARTING_CASH
          players.each { |player| bank.spend(cash[players.size], player) }
        end

        def init_companies(players)
          companies = super
          concessions? ? companies : companies.reject { |company| concession?(company) }
        end

        def num_certs(entity)
          super - entity.companies.count { |company| concession?(company) || face_down_private?(company) }
        end

        public :companies_sort

        def private_company?(company)
          !company_becomes_minor?(company) && !concession?(company)
        end

        # §10.4 needs a mutually agreed price. Until the seller can consent (#148 part 2),
        # buying a private/minor from another player is switched off; the bank stays open.
        def player_trade_enabled?
          false
        end

        def face_down_private?(company)
          @face_down_privates.include?(company)
        end

        def flip_private!(company)
          @face_down_privates << company
          company.revenue = 0
        end

        def company_status_str(company)
          'Face down' if face_down_private?(company)
        end

        def player_value(player)
          super - player.companies.select { |company| face_down_private?(company) }.sum(&:value)
        end

        def remove_private!(company)
          @face_down_privates.delete(company)
          company.close!
        end

        # ---- §14.8 Hochberg Mining & Lumber Co. --------------------------------------------

        # Revenue of the token per train phase, for every RR of the owner (counted as a town).
        HOCHBERG_REVENUE = { 2 => 10, 3 => 20, 4 => 20, 5 => 40, 6 => 40, 7 => 60, 8 => 60 }.freeze
        HOCHBERG_MIN_COST = 45
        # ASSUMPTION: no artwork yet, placeholder logo path (workshop #81).
        HOCHBERG_TOKEN_LOGO = '/logos/18_oe/hochberg.svg'

        def hochberg_company
          company_by_id('HMLC')
        end

        # Rough (green) terrain with a construction cost of at least 45; the hex may hold track and one
        # town (which the token replaces), but no city, grand city, metropolis, second town or token.
        def hochberg_hex?(hex)
          cost = hex.original_tile.upgrades.sum(&:cost)
          rough = self.class::EF_TERRAIN_AUGMENT['F']
          cost >= HOCHBERG_MIN_COST && (hex.original_tile.terrain & rough).any? &&
            hex.tile.cities.empty? && hex.tile.towns.size <= 1 && !metropolis_hex?(hex) && hex.tokens.empty?
        end

        def hochberg_hexes
          hexes.select { |hex| hochberg_hex?(hex) }
        end

        def hochberg_place_token!(hex)
          company = hochberg_company
          token = Engine::Token.new(company, logo: HOCHBERG_TOKEN_LOGO, simple_logo: HOCHBERG_TOKEN_LOGO, type: :hochberg)
          hex.place_token(token, logo: HOCHBERG_TOKEN_LOGO)
          @hochberg_hex = hex
          clear_graph
          @log << "#{company.name} places its token on #{hex.id}"
          flip_private!(company)
        end

        def hochberg_token_revenue
          current = @phase.name.to_i
          HOCHBERG_REVENUE.select { |phase, _| phase <= current }.values.last || HOCHBERG_REVENUE.values.first
        end

        # The token replaces the town of its hex for everyone; the owner's RRs count it as a town (not
        # against the train's town limit: ASSUMPTION, the rules text does not say).
        def hochberg_revenue_change(route, stops)
          return 0 unless @hochberg_hex && route.paths.any? { |path| path.hex == @hochberg_hex }

          replaced = stops.select { |stop| stop.town? && stop.hex == @hochberg_hex }
          change = -replaced.sum { |stop| stop.route_revenue(route.phase, route.train) }
          change += hochberg_token_revenue if route.train.owner&.owner == hochberg_company&.owner
          change
        end

        # ---- §14.9 Brandt & Brandau, Engineers ---------------------------------------------

        # Marker of a Brandt & Brandau token on the map. ASSUMPTION: no artwork yet, the logo path is a
        # placeholder (workshop #82).
        BBE_TOKEN_LOGO = '/logos/18_oe/bbe.svg'

        def bbe_company
          company_by_id('BBE')
        end

        # The rough (green: hill, mountain) hexes still unbuilt, without a city or metropolis: where the
        # free yellow lay may go. Set once as the hexes of the private's tile_lay ability.
        def setup_bbe_ability!
          @bbe_token_hexes = []
          ability = bbe_company&.all_abilities&.find { |a| a.type == :tile_lay }
          return unless ability

          rough = self.class::EF_TERRAIN_AUGMENT['F']
          ability.hexes = hexes.select do |hex|
            hex.tile.color == :white && hex.tile.cities.empty? && (hex.tile.terrain & rough).any? && !metropolis_hex?(hex)
          end.map(&:id)
        end

        # §14.9: only the RRs of the token owner's player may use the track of a marked hex.
        def bbe_blocked_for?(corporation)
          return false if @bbe_token_hexes.empty? || !corporation&.corporation?

          corporation.owner != bbe_company&.owner
        end

        def graph_skip_paths(corporation)
          return super unless bbe_blocked_for?(corporation)

          @bbe_token_hexes.flat_map { |hex| hex.tile.paths }.to_h { |path| [path, true] }
        end

        def bbe_place_token!(hex, company)
          token = Engine::Token.new(company, logo: BBE_TOKEN_LOGO, simple_logo: BBE_TOKEN_LOGO, type: :bbe)
          hex.place_token(token, logo: BBE_TOKEN_LOGO)
          @bbe_token_hexes << hex
          clear_graph
          @log << "#{company.name} token placed on #{hex.id}"
          # after the last token the certificate is turned face down
          flip_private!(company) if company.all_abilities.none? { |a| a.type == :tile_lay } && !face_down_private?(company)
        end

        def bbe_remove_token!(hex)
          token = hex.tokens.find { |t| t.type == :bbe }
          token.remove!
          @bbe_token_hexes.delete(hex)
          clear_graph
          @log << "Brandt and Brandau token removed from #{hex.id}"
          return unless @bbe_token_hexes.empty? && bbe_company.all_abilities.none? { |a| a.type == :tile_lay }

          remove_private!(bbe_company)
          @log << "#{bbe_company.name} is removed from the game"
        end

        def check_connected(route, corporation)
          return check_sea_route_connected(route, corporation) if sea_crossings(route).any?

          if bbe_blocked_for?(corporation) && route.paths.any? { |path| @bbe_token_hexes.include?(path.hex) }
            raise GameError, 'Route uses track marked by a Brandt and Brandau token'
          end

          return super unless wcf_restricted?(corporation)
          return if route.ordered_paths.each_cons(2).all? { |a, b| wcf_pass?(a, b) || a.connects_to?(b, corporation) }

          raise GameError, 'Route is not connected'
        end

        def init_stock_market
          G18OE::StockMarket.new(game_market, self.class::CERT_LIMIT_TYPES,
                                 multiple_buy_types: self.class::MULTIPLE_BUY_TYPES)
        end

        def ipo_name(_entity = nil)
          'Treasury'
        end

        # True once MAX_FLOATED_REGIONALS have been floated and the 6 remaining
        # unfloated regionals have been closed. This is the correct trigger for
        # "Major Railroad Phase" entry: conversions and secondary-share purchases
        # become available from this point on.
        def major_phase?
          return false if @corporations.any? { |corporation| corporation.type == :regional && !corporation.floated? }

          total_minors = corporations.count { |c| c.type == :minor }
          @minor_floated_regions.size >= total_minors
        end

        def can_hold_above_corp_limit?(_entity)
          true
        end

        def fulfilled_train_obligation?(entity)
          !phase.status.include?('train_obligation') || @fulfilled_train_obligation.include?(entity.id)
        end

        def fulfill_train_obligation!(entity)
          @fulfilled_train_obligation.add(entity.id)
        end

        # §11.6.4 para. 2: a player may not force a RR into first-round insolvency by
        # spending money on track or tokens. The rule undoes such spending (tokens first,
        # then paid track, each refunded); the engine instead refuses it up front: while the
        # reserved 2+2 is still owed, a paid lay or token is legal only if the RR's and its
        # president's cash still cover that 2+2 afterwards. ASSUMPTION (workshop #352): same
        # outcome, because in the first OR no money arrives between Track/Token and BuyTrain
        # (no train, no revenue; private income is paid at the start of the OR), and Track
        # comes before Token, so a token is what the guard drops first, as the rule does.
        # `cost` is the net spend (a patronage payout of the same lay already deducted).
        def first_round_spend_allowed?(entity, cost)
          reserve = first_round_train_reserve(entity)
          return true if reserve.nil? || !cost.positive?

          entity.cash + entity.owner.cash - cost >= reserve
        end

        def check_first_round_spend!(entity, cost, net_cost: cost, what: 'track')
          return if first_round_spend_allowed?(entity, net_cost)

          raise GameError, "#{entity.name} cannot spend #{format_currency(cost)} on #{what}: its cash and its " \
                           "president's would no longer cover the reserved 2+2 (§11.6.4)"
        end

        # Price of the reserved 2+2 the RR still has to buy (§11.6.1), or nil when it owes
        # none: obligation fulfilled or over, the RR already has a train, or no player owns it.
        def first_round_train_reserve(entity)
          return unless entity&.corporation? && entity.floated? && entity.trains.empty? && entity.owner&.player?
          return if fulfilled_train_obligation?(entity)

          depot.depot_trains.find { |train| train.name == '2+2' && train.from_depot? }&.price
        end

        # What fulfilling the patronage tile on this hex would pay now (§11.1.8), 0 without one.
        def patronage_payout(hex)
          payouts = hex.tile.patronage
          payouts ? payouts[patronage_color].to_i : 0
        end

        def non_starter_trains_available?
          major_phase? && @first_or_complete
        end

        def operating_order
          floated_minors_and_regionals = @minor_regional_order.select(&:floated?)
          golden_bell_order(floated_minors_and_regionals,
                            @corporations.select { |c| %i[major national].include?(c.type) && c.floated? }.sort)
        end

        def hex_within_national_region?(entity, hex)
          return true if entity.type == :major

          region = self.class::CORPORATIONS_TRACK_RIGHTS[entity.id] || @minor_floated_regions[entity.id]
          hexes = self.class::NATIONAL_REGION_HEXES[region]
          hexes&.include?(hex.coordinates) || false
        end

        def city_in_track_rights?(entity, hex)
          return true if entity.type == :major

          region_for_hex(hex) == entity_track_rights_zone(entity)
        end

        def region_for_hex(hex)
          self.class::CITY_NATIONAL_ZONE[hex.coordinates] ||
            self.class::NATIONAL_REGION_HEXES.find { |_, hexes| hexes.include?(hex.coordinates) }&.first
        end

        def region_available?(region)
          @minor_available_regions.key?(region)
        end

        def track_rights_cost(region)
          self.class::TRACK_RIGHTS_COST[region] || 0
        end

        # What a minor pays for its home token (§9.1 step 4): the chit's cost. A
        # minor that cannot afford any open zone in full (bought at a price below
        # every chit cost, e.g. a row reduced to 0 and taken by force) pays what
        # its treasury holds, so the float can finish (#367, assumption).
        def home_token_cost(minor, region)
          cost = track_rights_cost(region)
          return cost if @minor_available_regions.keys.any? { |r| track_rights_cost(r) <= minor.cash }

          [cost, minor.cash].min
        end

        def claim_region!(entity, region)
          @minor_floated_regions[entity.id] = region
          @minor_available_regions[region] -= 1
          @minor_available_regions.delete(region) if @minor_available_regions[region].zero?

          return unless self.class::ASTERISKED_ZONES.include?(region)

          @minor_asterisked_selected += 1
          return unless @minor_asterisked_selected >= self.class::ASTERISKED_ZONES_CAP

          self.class::ASTERISKED_ZONES.each { |z| @minor_available_regions.delete(z) }
        end

        def home_token_locations(corporation)
          available_regions = self.class::NATIONAL_REGION_HEXES.select { |key, _| @minor_available_regions.include?(key) }
          region_hexes = available_regions.values.flatten

          @hexes
            .select { |hex| region_hexes.include?(hex.coordinates) }
            .reject { |hex| (z = self.class::CITY_NATIONAL_ZONE[hex.coordinates]) && !@minor_available_regions.key?(z) }
            .select { |hex| hex.tile.cities.any? { |city| city.tokenable?(corporation, free: true) } }
            .reject { |hex| metropolis_hex?(hex) }
            .reject { |hex| self.class::MINOR_EXCLUDED_HOME_CITIES.include?(hex.coordinates) }
            .reject { |hex| railroad_home_hexes.include?(hex.coordinates) }
            .reject { |hex| minor_tokened?(hex) }
        end

        def railroad_home_hexes
          @corporations.reject { |c| c.type == :minor }.map(&:coordinates)
        end

        def minor_tokened?(hex)
          hex.tile.cities.any? { |city| city.tokens.any? { |token| token&.corporation&.type == :minor } }
        end

        def metropolis_hex?(hex)
          %w[A56 B41 C74 F87 K26 M28 M50 Q30 R55 Y14 AA82 AB51].include?(hex.coordinates)
        end

        def metropolis_tile?(tile)
          %w[OE4 OE5 OE6 OE7 OE8 OE12 OE13 OE14 OE15 OE16 OE17
             OE18 OE26 OE27 OE28 OE29 OE30 OE37 OE38 OE39 OE40 OE41].include?(tile.name.to_s)
        end

        def tile_point_budget(entity)
          budget = self.class::TILE_POINT_BUDGET[entity.type] || 0
          return budget if entity.type == :national

          entity.abilities.include?(@minor_g_ability) ? budget + 2 : budget
        end

        # §11.6.4: "bankruptcy" is the conversion of a major without a train into a national, offered
        # when its treasury and its president's cash (shares do not count, no sale is allowed) do not
        # reach the cheapest train in the Locomotive Works or the Open Market. Never a player bankruptcy.
        def can_go_bankrupt?(player, corporation)
          return false unless corporation&.corporation? && corporation.type == :major
          return false unless corporation.floated? && corporation.trains.empty?

          corporation.cash + player.cash < depot.min_depot_price
        end

        # §15.2: Orange Scroll Surveyors (or the major holding its charter).
        def minor_b?(entity)
          !@minor_b_ability.nil? && entity.abilities.include?(@minor_b_ability)
        end

        def can_buy_train_from_others?
          major_phase?
        end

        def train_obligation_active?
          phase.status.include?('train_obligation')
        end

        def upgrade_cost(tile, hex, entity, spender)
          base_cost = tile.upgrades.sum(&:cost)
          return super if base_cost.zero?

          zone_match = track_rights_zones(entity).any? do |zone|
            self.class::ZONE_DISCOUNT_ZONES.include?(zone) &&
              self.class::NATIONAL_REGION_HEXES[zone].include?(hex.coordinates)
          end

          ef_corp = terrain_augmented_by?(entity, tile)
          return super unless zone_match || ef_corp

          # §11.1.5: 20% zone discount, 50% with E/F on matching terrain. §15.5/§15.6: E/F alone
          # (no zone discount) give 33% (cost x 0.67, rounded down).
          cost = if zone_match
                   (base_cost * (1 - (ef_corp ? self.class::ZONE_TERRAIN_DISCOUNT_RATE : self.class::ZONE_DISCOUNT_RATE))).floor
                 else
                   base_cost * self.class::EF_TERRAIN_COST_FACTOR[0] / self.class::EF_TERRAIN_COST_FACTOR[1]
                 end
          discount = base_cost - cost
          if discount.positive?
            pct = (discount * 100.0 / base_cost).round
            label = ef_corp ? "#{zone_match ? "#{(self.class::ZONE_TERRAIN_DISCOUNT_RATE * 100).to_i}% zone+" : '33% '}#{ef_corp.name}" : "#{pct}% zone"
            @log << "#{spender.name} receives a #{label} discount of #{format_currency(discount)}"
          end
          cost
        end

        def track_rights_zones(entity)
          corp = owning_corporation(entity)
          return [] unless corp

          merged_zones = @merged_minors.fetch(corp, []).map { |minor| @minor_floated_regions[minor.id] }
          ([entity_track_rights_zone(corp)] + merged_zones).compact.uniq
        end

        def merge_candidates(player, minor)
          return [] unless @phase.available?('3')
          return [] if minor.type != :minor || !minor.floated? || minor.owner != player

          @corporations.select do |corporation|
            corporation.type == :major &&
              corporation.floated? &&
              corporation.president?(player) &&
              !@round.merged_majors.include?(corporation)
          end
        end

        def merge_targets(player, minor)
          merge_candidates(player, minor).select do |corporation|
            merge_share(corporation) || @loading || merge_connected?(minor, corporation)
          end
        end

        def merge_graph
          @merge_graph ||= Engine::Graph.new(self, no_blocking: true)
        end

        def merge_connected?(minor, major)
          nodes = merge_graph.connected_nodes(major)
          minor.placed_tokens.any? { |token| nodes.key?(token.city) }
        end

        def merge_share(major)
          major.treasury_shares.find { |share| !share.president } ||
            @share_pool.shares_by_corporation[major].first
        end

        def abandoned_minor_price
          self.class::ABANDONED_MINOR_PRICE
        end

        def abandoned_minors
          @corporations.select { |corporation| abandoned_minor?(corporation) }
        end

        def abandoned_minor?(corporation)
          corporation.type == :minor && corporation.floated? && !corporation.owner
        end

        # §11.6.5 (#353): an insolvent minor/regional has its charter or president's certificate
        # in the Open Market. §10 (RB l. 2925 ff.) allows a president's certificate there only
        # after a first-round insolvency, so the share's place is the insolvency state.
        def insolvent_corporations
          @corporations.select { |corporation| insolvent?(corporation) }
        end

        def insolvent?(corporation)
          %i[minor regional].include?(corporation.type) && corporation.floated? &&
            corporation.presidents_share&.owner == @share_pool
        end

        # §11.6.5 step 4: face value (£120 / 2 x par) plus the gap between treasury and the 2+2.
        def insolvent_buyback_price(corporation)
          face_value = if corporation.type == :minor
                         G18OE::Step::BuyTrain::MINOR_CHARTER_VALUE
                       else
                         corporation.par_price.price * 2
                       end
          reserved_price = self.class::TRAINS.find { |train| train[:name] == '2+2' }[:price]
          face_value + [reserved_price - corporation.cash, 0].max
        end

        def corporation_show_shares?(corporation)
          return false if abandoned_minor?(corporation)

          super
        end

        def abandon_minor!(minor)
          @log << "#{minor.name} is abandoned"
          minor.trains.dup.each { |train| @depot.reclaim_train(train) }
          minor.placed_tokens.each(&:remove!)
          # §9.5 step 4: the D minor's tokens go back to its charter
          green_junction_remove!(back_to_charter: true) if green_junction_holder?(minor)
          minor.spend(minor.cash, @bank) if minor.cash.positive?
          @share_pool.transfer_shares(minor.presidents_share.to_bundle, minor.ipo_owner, allow_president_change: false)
          minor.presidents_share.buyable = false
          minor.owner = nil
          @minor_regional_order.delete(minor)
          clear_graph
        end

        def merge_offer_majors(minor)
          owner = minor.owner
          @players.rotate(@players.index(owner) + 1).reject { |player| player == owner }.flat_map do |player|
            @corporations.select do |corporation|
              corporation.type == :major &&
                corporation.floated? &&
                corporation.president?(player) &&
                corporation.treasury_shares.any? { |share| !share.president } &&
                !@round.merged_majors.include?(corporation)
            end
          end
        end

        def add_minor_charter!(minor, major)
          @merged_minors[major] << minor
          return unless major.type == :major

          pay_minor_a_bonus!(minor, major) if minor.id == 'A'
          minor.abilities.dup.each do |ability|
            minor.remove_ability(ability)
            major.add_ability(ability)
          end
        end

        def pay_minor_a_bonus!(minor, major)
          ability = minor.abilities.first
          return if !ability || ability.used?

          amount = major.share_price.price
          @bank.spend(amount, major)
          ability.use!
          @log << "#{major.name} receives #{format_currency(amount)} from the bank for #{minor.name}"
        end

        def level8_train_available?
          @level_8_available || false
        end

        def event_level_8_available!
          @level_8_available = true
          @log << '-- Event: Level 8 trains are now available --'
        end

        def event_remainder_cash_added!
          return if @remainder_cash_added

          @remainder_cash_added = true
          remainder = self.class::REMAINDER_CASH
          @bank.add_cash(remainder)
          @log << "-- Event: #{format_currency(remainder)} remainder cash added to bank;" \
                  ' game ends after one more full OR set (sooner if bank breaks) --'
        end

        # UP movement at end of SR: only for majors and nationals that are fully player-held
        def sold_out_increase?(corporation)
          %i[major national].include?(corporation.type)
        end

        def event_consolidation_triggered!
          @consolidation_triggered = true
          @log << '-- Event: Consolidation phase triggered --'
        end

        def next_round!
          @round =
            case @round
            when Engine::Round::Operating
              @first_or_complete = true # Rule 8.3/11.6: level 3+ trains unblocked after first OR
              if @round.round_num < @operating_rounds
                or_round_finished
                new_operating_round(@round.round_num + 1)
              elsif @consolidation_triggered && !@consolidation_complete
                @turn += 1
                or_round_finished
                or_set_finished
                @log << '-- Consolidation Phase --'
                new_consolidation_round
              else
                @turn += 1
                or_round_finished
                or_set_finished
                new_stock_round
              end
            when Engine::Round::Auction
              init_round_finished
              reorder_players(silent: concessions.any?)
              concessions.any? ? new_concession_round : new_stock_round
            when Round::G18OE::Concession
              reorder_players_after_concessions!
              new_stock_round
            when Round::G18OE::Consolidation
              @consolidation_complete = true
              remove_major_par_markers!
              super
            when Engine::Round::Stock
              @reserved_shares = []
              remove_major_par_markers!
              round = super
              @operating_rounds = final_operating_rounds if @turn == @final_turn
              round
            else
              super
            end
        end

        def after_phase_change(name)
          super
          green_junction_phase_change!
          @national_formation_phase = name if self.class::NATIONAL_FORMATION_PHASES.include?(name)
          return unless name == self.class::PHASES.last[:name]

          @final_set_extended = @round.is_a?(Engine::Round::Operating) && final_or_in_set?(@round)
        end

        def final_operating_rounds
          @final_set_extended ? self.class::EXTENDED_FINAL_OPERATING_ROUNDS : super
        end

        # §10.2: 60 % of a major or national; PB 5.4: 70 % with two players.
        def major_max_ownership_percent
          @players.size == 2 ? self.class::TWO_PLAYER_MAJOR_MAX_OWNERSHIP_PERCENT : self.class::MAJOR_MAX_OWNERSHIP_PERCENT
        end

        def long_endgame?
          @optional_rules.include?(:long_endgame)
        end

        # §13: the last OR of the final turn only repeats the previous OR's payout. PB 5.3 (long_endgame)
        # plays it fully. A bank break ends the game after the current OR, so it never reaches this OR.
        def abbreviated_or?(round_num)
          !long_endgame? && !@final_turn.nil? && @turn == @final_turn && round_num == @operating_rounds
        end

        # Remembered at every dividend: what the next (abbreviated) OR repeats for this railroad.
        def record_payout!(entity, revenue, kind)
          @last_payouts[entity.id] = { revenue: revenue, kind: kind.to_sym, train_ids: entity.trains.map(&:id).sort }
        end

        # The payout the abbreviated OR repeats for entity, or nil when it has to be decided anew:
        # not in an abbreviated OR, no earlier payout, or its trains changed since (bought or rusted, §13).
        # round is the step's own round: during setup @round is still the previous one.
        def repeated_payout(entity, round)
          return unless round.respond_to?(:abbreviated?) && round.abbreviated?

          last = @last_payouts[entity.id]
          last if last && last[:train_ids] == entity.trains.map(&:id).sort
        end

        def place_major_par_marker!(corporation)
          corporation.max_ownership_percent = major_max_ownership_percent
          corporation.always_market_price = false
        end

        def remove_major_par_markers!
          @corporations.each { |c| c.always_market_price = true if c.type == :major }
        end

        def regionals_in_play
          @corporations.count { |corporation| corporation.type == :regional && corporation.ipoed }
        end

        # Regionals that have floated (president's share bought, §9.2). Only these end the
        # Regional/Minor RR Phase (§5.1.3, §8.2); parred ones are merely in play (#348).
        def regionals_floated
          @corporations.count { |corporation| corporation.type == :regional && corporation.floated? }
        end

        # §8.2: the six remaining un-floated regionals are removed when the 18th regional floats.
        # Returns true if regionals were removed.
        def close_unfloated_regionals_at_maximum!
          return false unless regionals_floated >= self.class::MAX_FLOATED_REGIONALS

          leftovers = @corporations.select { |corporation| corporation.type == :regional && !corporation.floated? }
          leftovers.each { |corporation| close_corporation(corporation) }
          !leftovers.empty?
        end

        # At most MAX_FLOATED_REGIONALS regionals may be parred or floated at the same time, since each
        # parred one can still float; the others are removed only when the 18th floats (#348).
        def can_par?(corporation, parrer)
          return false if corporation.type == :regional && regionals_in_play >= self.class::MAX_FLOATED_REGIONALS

          super
        end

        def removable_regional?(corporation)
          return false if corporation.type != :regional || corporation.ipoed
          return false unless @corporations.count { |c| c.type == :regional } > self.class::MAX_FLOATED_REGIONALS

          !@removed_regional_zones.include?(self.class::CORPORATIONS_TRACK_RIGHTS[corporation.id])
        end

        def remove_regional!(corporation)
          @removed_regional_zones << self.class::CORPORATIONS_TRACK_RIGHTS[corporation.id]
          close_corporation(corporation)
        end

        def parred_regional?(corporation)
          corporation.type == :regional && corporation.ipoed && !corporation.floated?
        end

        def reserved_shares?
          @players.size > 2
        end

        def reserved_share(corporation)
          return unless corporation.type == :regional

          @reserved_shares.find { |share| share.corporation == corporation && share.owner == corporation.ipo_owner }
        end

        def can_reserve_regional?(player, corporation)
          reserved_shares? &&
            @turn == 1 &&
            corporation.type == :regional &&
            corporation.president?(player) &&
            @reserved_shares.none? { |share| share.corporation.owner == player } &&
            corporation.ipo_shares.count { |share| !share.president } == 2
        end

        def reserve_share!(corporation)
          @reserved_shares << corporation.ipo_shares.reject(&:president).last
        end

        def status_str(corporation)
          "Share reserved by #{corporation.owner.name}" if reserved_share(corporation)
        end

        def status_array(corporation)
          [['Orient Express marker']] if orient_express_marker?(corporation)
        end

        def orient_express_marker?(corporation)
          @orient_express_markers.include?(corporation)
        end

        def place_orient_express_marker!(corporation)
          @orient_express_markers << corporation unless orient_express_marker?(corporation)
        end

        def float_corporation(corporation)
          super
          return unless corporation.type == :regional

          pay_home_token_cost!(corporation)
        end

        def new_concession_round
          @log << '-- Concession RR Phase --'
          # Closing a concession drops its owner; remember who held which one (#121).
          @concession_owners = concessions.to_h { |concession| [concession.id, concession.owner&.id] }
          Round::G18OE::Concession.new(self, [
            G18OE::Step::HomeToken,
            G18OE::Step::Concession,
          ])
        end

        def reorder_players_after_concessions!
          @players.rotate!(@players.index(@round.entities.last) + 1)
          @log << "#{@players.first.name} has priority deal"
        end

        def new_consolidation_round
          @merge_graph&.clear
          Round::G18OE::Consolidation.new(self, [
            Engine::Step::DiscardTrain,
            G18OE::Step::MergeToken,
            G18OE::Step::MergeDiscardTrain,
            G18OE::Step::MergeMinor,
            G18OE::Step::MergeOffer,
            G18OE::Step::Consolidate,
          ])
        end

        def upgrades_to_correct_label?(from, to)
          return true if from.label == to.label
          return false if from.label && !to.label

          case from.hex.coordinates
          when 'K26', 'Y14', 'R55'
            to.label.to_s.include?('A')
          when 'M50'
            to.label.to_s.include?('B')
          when 'AA82'
            to.label.to_s.include?('C')
          when 'AB51'
            to.label.to_s.include?('N')
          when 'Q30'
            to.label.to_s.include?('P')
          when 'C74'
            to.label.to_s.include?('S')
          end
        end

        def company_becomes_minor?(company)
          corp = @corporations.find { |c| c.name == company.sym }
          return false unless corp

          corp.type == :minor
        end

        def form_button_text(_entity)
          'Float'
        end

        def pay_home_token_cost!(corporation)
          cost = TRACK_RIGHTS_COST[CORPORATIONS_TRACK_RIGHTS[corporation.id]]
          corporation.spend(cost, @bank) if cost&.positive?
        end

        def add_new_share(share)
          owner = share.owner
          corporation = share.corporation
          corporation.share_holders[owner] += share.percent if owner
          owner.shares_by_corporation[corporation] << share
          @_shares[share.id] = share
        end

        def issuable_shares(entity)
          return [] if !entity.corporation? || entity.type != :major

          bundles_for_corporation(entity, entity)
            .select { |bundle| @share_pool.fit_in_bank?(bundle) }
        end

        def redeemable_shares(entity)
          return [] if !entity.corporation? || entity.type != :major

          bundles_for_corporation(@share_pool, entity)
            .reject { |bundle| entity.cash < bundle.price }
        end

        def value_for_dumpable(player, corporation)
          return 0 if corporation.type == :regional

          super
        end

        def stock_round
          @merge_graph&.clear
          Round::Stock.new(self, [
            Engine::Step::DiscardTrain,
            G18OE::Step::HomeToken,
            G18OE::Step::MergeToken,
            G18OE::Step::MergeDiscardTrain,
            G18OE::Step::MergeMinor,
            G18OE::Step::ReserveShare,
            G18OE::Step::BuySellParShares,
          ])
        end

        def new_auction_round
          Round::Auction.new(self, [
            G18OE::Step::WaterfallAuction,
          ])
        end

        def operating_round(round_num)
          return abbreviated_operating_round(round_num) if abbreviated_or?(round_num)

          Round::G18OE::Operating.new(self, [
            G18OE::Step::GoldenBellOrder,
            G18OE::Step::ConvertToNational,
            G18OE::Step::Bankrupt,
            G18OE::Step::DiscardTrain,
            Engine::Step::HomeToken,
            G18OE::Step::HochbergToken,
            G18OE::Step::SpecialTrack,
            G18OE::Step::HomeHexConsent,
            G18OE::Step::Track,
            G18OE::Step::SpecialToken,
            G18OE::Step::Token,
            G18OE::Step::Route,
            G18OE::Step::Dividend,
            G18OE::Step::OrientExpressBonus,
            G18OE::Step::BuyTrain,
            G18OE::Step::IssueShares,
          ], round_num: round_num)
        end

        # §13: no track, tokens or train buying; routes are only re-run for a changed train set.
        def abbreviated_operating_round(round_num)
          Round::G18OE::Operating.new(self, [
            G18OE::Step::Route,
            G18OE::Step::Dividend,
            G18OE::Step::OrientExpressBonus,
          ], round_num: round_num)
        end

        def token_owner(entity)
          return @round.current_operator if entity&.company? && entity.owner&.player? && @round.operating?

          super
        end

        def init_graph
          G18OE::Graph.new(self)
        end

        def check_other(route)
          super

          check_sea_crossings!(route)
          hexes = route.visited_stops.reject(&:town?).map(&:hex)
          raise GameError, 'Route visits same city hex twice' if hexes.size != hexes.uniq.size
          return unless combined_train?(route.train)

          raise GameError, 'Combined trains may only run an Orient Express route' unless orient_express_run?(route)
        end

        def double_head_candidates(corporation)
          return [] if !corporation.corporation? || corporation.type != :major
          return [] if corporation.trains.any? { |train| combined_train?(train) }

          corporation.trains.reject { |train| train.operated || !train.rusts_on }
        end

        def non_permanent_trains?
          @depot.trains.any? { |train| train.rusts_on && !train.rusted }
        end

        def combined_train?(train)
          @round.respond_to?(:combined_trains) && @round.combined_trains.key?(train)
        end

        def distance(train)
          [train.distance[1]['pay'], train.distance[0]['pay']]
        end

        def orient_express_origin_hexes
          @orient_express_origin_hexes ||=
            location_hexes(self.class::ORIENT_EXPRESS_ORIGINS).select { |hex| hex.tile.offboards.empty? }
        end

        def orient_express_destination_hexes
          @orient_express_destination_hexes ||= location_hexes(self.class::ORIENT_EXPRESS_DESTINATIONS)
        end

        def orient_express_reachable?(corporation)
          connected = graph_for_entity(corporation).connected_nodes(corporation).keys.map(&:hex)
          connected.intersect?(orient_express_origin_hexes) && connected.intersect?(orient_express_destination_hexes)
        end

        def orient_express_run?(route)
          return false unless route.corporation&.type == :major

          visited = route.visited_stops.map(&:hex)
          visited.intersect?(orient_express_destination_hexes) && visited.intersect?(orient_express_origin_hexes)
        end

        def orient_express_route(routes)
          routes.find { |route| orient_express_run?(route) }
        end

        def orient_express_train_revenue(routes)
          routes.select { |route| orient_express_run?(route) }.map do |route|
            bonus = orient_express_bonus_route?(route) ? 0 : self.class::ORIENT_EXPRESS_BONUS[route.phase.name]
            route.revenue + bonus
          end.max
        end

        # Base#compute_stops scores every combination of the visited stops; with
        # towns 'visit' 99 a 5+5 train on a 15-stop route tries C(15,10) = 3003
        # sets, which was 90 % of the route search in green networks (#319).
        # When the distance rows are nested (each row's node types include those
        # of the row before, as here: towns, then city/offboard/town), the stop
        # sets that fit form a matroid, so taking stops best revenue first while
        # they still fit gives the best set. The Orient Express bonus does not
        # depend on the chosen stops. Other distance shapes use the base search.
        def compute_stops(route, train = nil)
          train ||= route.train
          rows = train.distance
          return super if rows.is_a?(Numeric)

          units = sea_units(route)
          rows = distance_rows_after_sea(rows, units) if units.positive?

          rows = rows.sort_by { |h| h['nodes'].size }
          return super unless rows.each_cons(2).all? { |a, b| (a['nodes'] - b['nodes']).empty? }

          visits = revenue_stops(route)
          return [] if visits.empty?

          revenue = visits.to_h { |stop| [stop, stop.route_revenue(route.phase, train)] }
          ranked = visits.each_with_index.sort_by { |stop, i| [-revenue[stop], i] }.map(&:first)
          best = greedy_stops(ranked, rows, train)
          if train.requires_token && best.none? { |stop| stop.tokened_by?(route.corporation) }
            best = ranked.select { |stop| stop.tokened_by?(route.corporation) }
                         .map { |token| greedy_stops([token] + (ranked - [token]), rows, train) }
                         .max_by { |stops| stops.sum { |stop| revenue[stop] } } || []
          end
          best.sum { |stop| revenue[stop] }.positive? ? visits & best : []
        end

        # §11.3.3, §11.3.4, §11.3.7: sea zones and the ferry distance take places of the cities' row; the base check
        # runs on the rest.
        def check_distance(route, visits, train = nil)
          train ||= route.train
          units = sea_units(route)
          return super if units.zero? || train.distance.is_a?(Numeric)

          rows = train.distance
          places = rows.select { |row| row['nodes'].include?('city') }.sum { |row| row['visit'] || row['pay'] }
          raise RouteTooLong, "Sea distance #{units} is too much for a #{train.name} train" if units > places

          super(route, visits, SeaTrain.new(distance_rows_after_sea(rows, units)))
        end

        # What the base distance check sees of a train that rides a ferry: its rows, less the ferry distance.
        SeaTrain = Struct.new(:distance)

        def route_distance_str(route)
          units = sea_units(route)
          units.zero? ? super : "#{super}+#{units}~"
        end

        # Places each stop, in the given order, in the first row with room for
        # its type (the slot rule of Base#compute_stops); stops without room are left out.
        def greedy_stops(ranked, rows, train)
          used = Array.new(rows.size, 0)
          ranked.select do |stop|
            row = rows.index.with_index { |h, i| h['nodes'].include?(stop_type(stop, train)) && used[i] < h['pay'] }
            used[row] += 1 if row
            row
          end
        end

        def revenue_for(route, stops)
          revenue = super + hochberg_revenue_change(route, stops) + green_junction_revenue(route)
          revenue += self.class::ORIENT_EXPRESS_BONUS[route.phase.name] if orient_express_bonus_route?(route)
          revenue
        end

        def revenue_str(route)
          str = super
          str = "#{str} + Green Junction" if green_junction_revenue(route).positive?
          orient_express_bonus_route?(route) ? "#{str} + Orient Express" : str
        end

        # §11.3.8: a ferry, and the track section joining it to its city, is sea traffic; any number of trains of
        # one RR may use it. Everything else keeps the base rule (a track section only once). Both hooks are the
        # upstream ones (cf. 1817, 1861); the ferry paths are simply left out.
        def check_overlap(routes)
          return super unless routes.any? { |route| route.paths.any? { |path| ferry_path?(path) } }

          super(routes.map { |route| RouteWithoutFerries.new(route, self) })
        end

        def compute_other_paths(routes, route)
          super.reject { |path| ferry_path?(path) }
        end

        # A ferry line (blue path in a sea hex) or a path that leaves its hex over a ferry end (PORTS ... ferries:).
        # Asked for every path at every overlap check of the route search, so the answer is kept per path object
        # (a path's colour, hex and exits do not change once the tile is laid; #371: +20% search time without).
        def ferry_path?(path)
          @ferry_paths ||= {}.compare_by_identity
          return @ferry_paths[path] if @ferry_paths.key?(path)

          @ferry_paths[path] = ferry_path_uncached?(path)
        end

        def ferry_path_uncached?(path)
          return true if ferry_line?(path)

          ports = self.class::PORTS[path.hex.id]
          !!ports && path.exits.any? { |exit| ports.dig(exit, :ferries) }
        end

        # What check_overlap sees of a route: its paths minus the ferry paths.
        RouteWithoutFerries = Struct.new(:route, :game) do
          def paths
            route.paths.reject { |path| game.ferry_path?(path) }
          end
        end

        def wcf_pass?(entering, leaving)
          [entering, leaving].all? { |path| path.nodes.include?(lille_city) } &&
            [entering, leaving].any? { |path| wcf_path?(path) }
        end

        def lille_city
          hex_by_id('N31').tile.cities.first
        end

        def wcf_path?(path)
          path.exits.include?(self.class::PORTS['N31'].keys.first)
        end

        def wcf_restricted?(corporation)
          wcf_placeholder && lille_city.blocks?(corporation)
        end

        def remove_wcf_placeholder!
          @wcf_placeholder.remove!
          @wcf_placeholder = nil
        end

        def sea_zone(hex_id)
          @sea_zone_by_hex ||= self.class::SEA_ZONES.each_with_object({}) do |(zone, data), by_hex|
            data[:hexes].each { |id| by_hex[id] = zone }
          end
          @sea_zone_by_hex[hex_id]
        end

        def sea(zone)
          self.class::SEA_ZONES[zone][:sea]
        end

        def port_sea_zone(hex_id, exit)
          return sea_zone(self.class::PORTS[hex_id][:offshore][:hex]) if exit == :offshore

          neighbor = hex_by_id(hex_id).all_neighbors[exit]
          neighbor && sea_zone(neighbor.id)
        end

        def sea_zone_neighbors
          @sea_zone_neighbors ||= begin
            neighbors = self.class::SEA_ZONES.keys.to_h { |zone| [zone, []] }
            self.class::SEA_ZONES.each do |zone, data|
              data[:hexes].each do |id|
                hex_by_id(id).all_neighbors.each_value do |neighbor|
                  other = sea_zone(neighbor.id)
                  neighbors[zone] << other if other && other != zone
                end
              end
            end
            self.class::CHANNEL_PASSAGES.each do |a, b|
              neighbors[a] << b
              neighbors[b] << a
            end
            neighbors.transform_values(&:uniq)
          end
        end

        def sea_zone_distance(from_zone, to_zone)
          @sea_zone_distances ||= {}
          @sea_zone_distances[from_zone] ||= begin
            distance = { from_zone => 1 }
            queue = [from_zone]
            until queue.empty?
              zone = queue.shift
              sea_zone_neighbors[zone].each do |other|
                next if distance.key?(other)

                distance[other] = distance[zone] + 1
                queue << other
              end
            end
            distance
          end
          @sea_zone_distances[from_zone][to_zone]
        end

        def port_distance(from_port, to_port)
          sea_zone_distance(port_sea_zone(*from_port), port_sea_zone(*to_port))
        end

        # Minor E / F charters whose ability (bound to the ability object, so it survives a merge into
        # a major) the entity holds and whose terrain colour the tile's hex has.
        def terrain_augmenters(entity, tile)
          corp = owning_corporation(entity)
          return [] unless corp

          self.class::EF_TERRAIN_AUGMENT.filter_map do |id, terrains|
            ability = @ef_abilities[id]
            corporation_by_id(id) if ability && corp.abilities.include?(ability) && (tile.terrain & terrains).any?
          end
        end

        def terrain_augmented_by?(entity, tile)
          terrain_augmenters(entity, tile).first
        end

        # Charters (E/F ids) whose extra tile point the entity holds, matching or not.
        def ef_bonus_ids(entity)
          corp = owning_corporation(entity)
          return [] unless corp

          @ef_abilities.select { |_id, ability| ability && corp.abilities.include?(ability) }.keys
        end

        # ---- Nationals: formation (§9.4) ------------------------------------------

        # Phase#buying_train! calls this right after the phase change, with the buyer. When the
        # change began Train Phase 4, 6 or 8, the trains rusting now stay with a major that converts
        # ("Majors that choose to convert ... do not remove their level 2/3/4 trains") and with every
        # national (§9.4: a national "retains all trains ..., including rusted trains").
        def rust_trains!(train, entity)
          phase = @national_formation_phase
          @national_formation_phase = nil
          rusting = trains.select do |t|
            !t.rusted && t.owner.respond_to?(:corporation?) && t.owner.corporation? &&
              %i[major national].include?(t.owner.type) && rust?(t, train)
          end.group_by(&:owner)
          super
          rusting.each { |owner, kept| return_rusted_trains!(owner, kept) if owner.type == :national }
          start_national_formation!(phase, entity, rusting.reject { |owner, _| owner.type == :national }) if phase
        end

        # The majors the player may convert now (§9.4: "one or more of their majors").
        def national_candidates(player)
          return [] unless player&.player?

          @corporations.select { |c| c.type == :major && c.floated? && !c.closed? && c.owner == player }
        end

        # The player whose turn it is to form nationals, nil when no formation is under way.
        def national_formation_player
          return unless @national_formation

          @national_formation[:players].find { |player| !national_candidates(player).empty? }
        end

        def national_formation_done!(player)
          return unless @national_formation

          @national_formation[:players].delete(player)
          @national_formation = nil unless national_formation_player
        end

        # §9.4 steps 1 to 4, then the charter is flipped. Trains stay (including the ones that
        # rusted at this phase change); the share price marker stays; shares stay with the players.
        def form_national!(corporation)
          @log << "#{corporation.name} forms a national (§9.4)"
          national_cash_to_bank!(corporation)
          national_treasury_to_market!(corporation)
          national_tokens_off!(corporation)
          national_charter_assets_off!(corporation)
          corporation.type = :national
          kept = @national_formation&.dig(:rusted)&.delete(corporation)
          return_rusted_trains!(corporation, kept) if kept
          @national_formation = nil if @national_formation && !national_formation_player
          clear_graph
        end

        private

        def start_national_formation!(phase, entity, rusting)
          buyer = entity.respond_to?(:player) ? entity.player : nil
          order = @players.rotate(@players.index(buyer) || 0)
          return if order.all? { |player| national_candidates(player).empty? }

          @national_formation = { phase: phase, players: order, rusted: rusting }
          @log << "-- Train Phase #{phase}: nationals may form, beginning with " \
                  "#{national_formation_player.name} (§9.4) --"
        end

        def return_rusted_trains!(corporation, kept)
          kept.each do |train|
            train.owner = corporation
            corporation.trains << train
          end
          @crowded_corps = nil
          @log << "#{corporation.name} keeps its rusted #{kept.map(&:name).join(', ')}"
        end

        # §9.4 step 1: cash to the bank.
        def national_cash_to_bank!(corporation)
          return unless corporation.cash.positive?

          @log << "#{corporation.name} pays #{format_currency(corporation.cash)} into the bank"
          corporation.spend(corporation.cash, @bank)
        end

        # §9.4 step 1: treasury certificates to the Open Market. Not a sale: the share price does not
        # move and the 50 % Open Market limit may be exceeded for a while (§10.1).
        # The national's Pullman also goes to the Open Market (§9.4 step 1): Pullman cars are #55.
        def national_treasury_to_market!(corporation)
          shares = corporation.treasury_shares.reject(&:president)
          return if shares.empty?

          bundle = Engine::ShareBundle.new(shares)
          @share_pool.transfer_shares(bundle, @share_pool, allow_president_change: false)
          @log << "#{corporation.name} places #{bundle.percent}% of its treasury in the Open Market"
        end

        # §9.4 step 2 and step 4 (tokens on the charter), §11.2.2 "Nationals may never have tokens
        # on the Map". Removing the White Cliffs Ferry token opens Lille for good (§11.2.2).
        def national_tokens_off!(corporation)
          placed = corporation.placed_tokens
          wcf_token = placed.find { |token| lille_city.extra_tokens.include?(token) }
          placed.each(&:remove!)
          corporation.tokens.clear
          @log << "#{corporation.name} removes its #{placed.size} token(s) from the map" unless placed.empty?
          open_lille! if wcf_token
        end

        # §11.2.2: "If the token on the White Cliffs Ferry token position is removed due to the
        # formation of a national, Lille becomes permanently open for all RRs to pass through."
        # ASSUMPTION (workshop #53): open as before the ferry was used, so the placeholder that
        # keeps the ferry passage through Lille free goes back into the extra position for good.
        def open_lille!
          setup_wcf_placeholder!
          @log << 'The White Cliffs Ferry position in Lille is free again: Lille stays open for good (§11.2.2)'
        end

        # §9.4 step 4: every other asset on the charter except trains goes. Merged-minor track
        # rights follow in the §9.5 step; port authorities (#56) and private markers (S8) do not
        # exist yet and join here with their issues.
        def national_charter_assets_off!(corporation)
          return unless orient_express_marker?(corporation)

          @orient_express_markers.delete(corporation)
          @log << "#{corporation.name} loses its Orient Express marker"
        end

        def location_hexes(names)
          self.class::LOCATION_NAMES.filter_map { |id, name| hex_by_id(id) if names.include?(name) }
        end

        def orient_express_bonus_route?(route)
          orient_express_run?(route) && route.equal?(orient_express_route(route.routes.empty? ? [route] : route.routes))
        end

        def entity_track_rights_zone(entity)
          corp = owning_corporation(entity)
          return nil unless corp

          self.class::CORPORATIONS_TRACK_RIGHTS[corp.id] || @minor_floated_regions[corp.id]
        end

        def owning_corporation(entity)
          resolved = entity.corporation? ? entity : entity.owner
          resolved&.corporation? ? resolved : nil
        end
      end
    end
  end
end
