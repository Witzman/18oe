# frozen_string_literal: true

require_relative '../../../step/track'
require_relative 'skip_abbreviated_round'

module Engine
  module Game
    module G18OE
      module Step
        class Track < Engine::Step::Track
          include SkipAbbreviatedRound

          attr_reader :points_used

          def setup
            super
            @points_used = 0
            @refused_home_hexes = []
          end

          # RB 11.1.9: a yellow lay in a floated RR's home hex waits for its president (Step::HomeHexConsent).
          def process_lay_tile(action)
            presidents = @consented_lay.equal?(action) ? [] : @game.home_hex_consent_needed(action.entity, action.hex, action.tile)
            return super if presidents.empty?

            check_home_lay!(action)
            @round.pending_home_lay = { action: action, presidents: presidents }
            @game.log << "#{action.entity.name} asks #{presidents.map(&:name).join(', ')} for permission to lay " \
                         "yellow track in the home hex #{action.hex.id}"
          end

          def lay_with_consent!(action)
            @consented_lay = action
            process_lay_tile(action)
          ensure
            @consented_lay = nil
          end

          def refuse_home_lay!(hex)
            @refused_home_hexes << hex
          end

          # The held lay must be one the step would take, so nobody is asked about an impossible lay.
          def check_home_lay!(action)
            entity = action.entity
            hex = action.hex
            raise GameError, "#{hex.id} is not available to #{entity.name}" unless available_hex(entity, hex)

            tile = upgradeable_tiles(entity, hex).find { |t| t.name == action.tile.name }
            raise GameError, "#{hex.tile.name} is not upgradeable to #{action.tile.name}" unless tile
            raise GameError, "#{action.tile.name} is not legally rotated" unless tile.legal_rotations.include?(action.rotation)
          end

          def potential_tile_colors(entity, hex)
            colors = super
            colors << :green if right_of_way?(entity, hex)
            colors
          end

          def legal_tile_rotation?(entity_or_entities, hex, tile)
            return false unless super
            return true if @game.phase.tiles.include?(tile.color)

            home_connectable?(Array(entity_or_entities).first, 0, hex => tile)
          end

          # With `cash` the search also counts the terrain cost of the lays and rejects a route whose lays the RR cannot pay
          # or that would leave it unable to buy its reserved 2+2 (RB 11.1.9 "without causing a first turn bankruptcy").
          def home_connectable?(entity, points, laid = {}, home = nil, cash = nil)
            return false unless (home ||= entity.tokens.first&.city)

            cheapest = {}
            queue = home.exits.map { |exit| [home.hex, exit, 0, 0] } +
                    affordable_lay_ends(entity, yellow_lay_ends(entity, home.hex, home.tile, 0, points), 0, cash)
            until queue.empty?
              hex, exit, cost, money = queue.shift
              next if cheapest[[hex.id, exit]] && cheapest[[hex.id, exit]].all? { |c, m| c <= cost && m <= money }

              (cheapest[[hex.id, exit]] ||= []) << [cost, money]
              crossings(hex, exit).each do |neighbor, edge|
                tile = laid[neighbor] || neighbor.tile
                paths = tile.paths.select { |path| path.exits.include?(edge) }.flat_map { |path| path.junction&.paths || [path] }
                return true if paths.any? { |path| path.nodes.any? { |node| node != home } }

                lay_ends = affordable_lay_ends(entity, yellow_lay_ends(entity, neighbor, tile, cost, points), money, cash)
                return true if !lay_ends.empty? && !tile.city_towns.empty?

                queue.concat(paths.flat_map(&:exits).map { |track_exit| [neighbor, track_exit, cost, money] }, lay_ends)
              end
            end
            false
          end

          # The lay ends of yellow_lay_ends with the money of the lay added; without `cash` no money is counted.
          def affordable_lay_ends(entity, lay_ends, money, cash)
            lay_ends.filter_map do |hex, exit, cost|
              total = money + (cash ? hex.tile.upgrades.sum(&:cost) : 0)
              next if cash && (total > cash || !@game.first_round_spend_allowed?(entity, total))

              [hex, exit, cost, total]
            end
          end

          def tile_points_left(entity)
            remaining_tile_points(entity)
          end

          # The bookkeeping of a lay made by a private (SpecialTrack): the RR's tile points are spent as in its own lay.
          def record_special_lay!(entity, action, old_tile, points_cost)
            @points_used += points_cost
            @game.after_lay_tile(entity, old_tile, action.tile)
            @round.num_laid_track += 1
            @round.laid_hexes << action.hex
          end

          # RB 14.9: another RR may remove a Brandt & Brandau token: it pays the hex's original terrain cost (a national
          # only the tile point) and one tile point (two on a metropolis), and lays no track.
          def bbe_removal_points(hex)
            @game.metropolis_hex?(hex) ? 2 : 1
          end

          def bbe_removal_money(entity, hex)
            @game.upgrade_cost(hex.original_tile, hex, entity, entity)
          end

          def bbe_removable_hexes(entity)
            return [] unless @game.bbe_blocked_for?(entity)

            @game.bbe_token_hexes.select { |hex| bbe_removal_points(hex) <= remaining_tile_points(entity) }
          end

          def actions(entity)
            actions = super
            return actions unless entity == current_entity && !bbe_removable_hexes(entity).empty?

            actions.empty? ? %w[remove_hex_token pass] : actions + %w[remove_hex_token]
          end

          def process_remove_hex_token(action)
            entity = action.entity
            hex = action.hex
            raise GameError, "No Brandt and Brandau token on #{hex.id} to remove" unless bbe_removable_hexes(entity).include?(hex)

            money = bbe_removal_money(entity, hex)
            raise GameError, "#{entity.name} cannot pay #{@game.format_currency(money)}" if money > entity.cash

            @game.check_first_round_spend!(entity, money)
            entity.spend(money, @game.bank) if money.positive?
            points = bbe_removal_points(hex)
            @points_used += points
            @game.log << "#{entity.name} pays #{@game.format_currency(money)} and #{points} tile point(s) to remove " \
                         "the token on #{hex.id}"
            @game.bbe_remove_token!(hex)
            pass! unless can_lay_tile?(entity)
          end

          def can_lay_tile?(entity)
            return true if @game.track_token_placeable?(entity)

            points_available = remaining_tile_points(entity)
            return false if !points_available.positive? && !@game.zero_point_tile_lays_available?(entity)

            !entity.tokens.empty? || @game.national?(entity)
          end

          def auto_actions(entity)
            return unless actions(entity).include?('lay_tile')
            return if remaining_tile_points(entity).positive?
            return if @game.track_token_placeable?(entity)

            hexes = @game.graph_for_entity(entity).connected_hexes(entity).keys
            return if hexes.any? { |hex| available_hex(entity, hex) }

            [Engine::Action::Pass.new(entity)]
          end

          def get_tile_lay(entity)
            @game.tile_point_budget(entity)
          end

          def description
            'Lay Track'
          end

          def help
            entity = current_entity
            tile_lay = remaining_tile_points(entity)
            text = "#{tile_lay} track points"
            abilities = @game.terrain_point_abilities(entity)
            return text if abilities.empty?

            points = abilities.keys.map { |color| "1 #{color}-terrain point" }.join(' + ')
            "#{text} + #{points} (yellow lays only)"
          end

          def lay_tile_action(action)
            tile = action.tile
            old_tile = action.hex.tile
            points_available = remaining_tile_points(action.entity)
            right_of_way = !@game.phase.tiles.include?(tile.color)
            raise GameError, 'Right-of-Way is not available' if right_of_way && !right_of_way?(action.entity, action.hex)

            points_cost = right_of_way ? points_available : @game.tile_point_cost(action.entity, old_tile: old_tile)
            raise GameError, 'Cannot lay an upgrade now' if tile.color != :yellow && points_cost > points_available
            raise GameError, 'Cannot lay a yellow now' if tile.color == :yellow && points_cost > points_available

            tile.rotate!(action.rotation)
            action.extra_cost = cross_water_fee(action) unless @game.loading
            lay_tile(action, extra_cost: action.extra_cost || 0)
            @game.after_lay_tile(action.entity, old_tile, tile)
            @game.fulfill_patronage!(action.entity, action.hex)
            if track_upgrade?(old_tile, tile, action.hex)
              @round.upgraded_track = true
              @round.num_upgraded_track += 1
            end
            @round.num_laid_track += 1
            @round.laid_hexes << action.hex
            @points_used += points_cost
          end

          # RB 11.6.4 para. 2: no paid lay that leaves the reserved 2+2 unpayable. The patronage payout of the same lay
          # counts against the cost.
          def pay_tile_cost!(entity_or_entities, tile, rotation, hex, spender, cost, extra_cost)
            @game.check_first_round_spend!(spender, cost, net_cost: cost - @game.patronage_payout(hex))
            super
          end

          def tracker_available_hex(entity, hex)
            return nil if @refused_home_hexes&.include?(hex)

            return nil unless @game.hex_within_national_region?(entity, hex)

            connected = hex_neighbors(entity, hex)
            return nil unless connected

            return nil if hex.tile.color == :blue

            points_available = remaining_tile_points(entity)
            cost = @game.tile_point_cost(entity, old_tile: hex.tile)
            return nil if cost > points_available && !right_of_way?(entity, hex)

            connected
          end

          private

          def right_of_way?(entity, hex)
            points = remaining_tile_points(entity)
            @game.players.size > 2 &&
              !@game.phase.tiles.include?(:green) &&
              !entity.operated? &&
              hex.tile.color == :yellow &&
              hex.tile.cities.empty? &&
              points.positive? &&
              (@game.loading || !home_connectable?(entity, points))
          end

          def yellow_lay_ends(entity, hex, tile, cost, points)
            return [] if tile.color != :white || !@game.hex_within_national_region?(entity, hex)

            cost += @game.tile_point_cost(entity, old_tile: tile)
            return [] if cost > points
            return [] unless @game.tiles.any? { |yellow| yellow.color == :yellow && @game.upgrades_to?(tile, yellow) }

            (0..5).map { |exit| [hex, exit, cost] }
          end

          def crossings(hex, exit)
            ferries = @game.ferry_links(hex.id, exit).map { |(hex_id, edge), _distance| [@game.hex_by_id(hex_id), edge] }
            neighbor = hex.neighbors[exit]
            return ferries if !neighbor || @game.sea_exit?(hex.id, exit)

            ferries << [neighbor, Engine::Hex.invert(exit)]
          end

          def remaining_tile_points(entity)
            get_tile_lay(entity) - @points_used
          end

          def cross_water_fee(action)
            fee = @game.cross_water_tile_fee(action.entity, action.hex, action.tile)
            return fee if !action.extra_cost || action.extra_cost == fee

            raise GameError, "Cross-water fee is #{@game.format_currency(fee)}, not #{@game.format_currency(action.extra_cost)}"
          end
        end
      end
    end
  end
end
