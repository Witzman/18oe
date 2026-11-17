# frozen_string_literal: true

require_relative '../../../step/track'

module Engine
  module Game
    module G18OE
      module Step
        class Track < Engine::Step::Track
          def setup
            super
            @points_used = 0
            @ef_bonus_used = []
            @right_of_way_used = false
            @right_of_way_memo = {}
            @refused_home_hexes = []
            @consented_lay = nil
          end

          attr_reader :points_used

          # ---- §11.1.9 Right-of-Way (Game::RightOfWay) ----------------------------------------

          # Part 1: may the RR lay its one green non-city tile now? Decided on the map as it is (memo per
          # lay and cash, so the search runs once per state, live and in a replay alike).
          def right_of_way_available?(entity)
            return false if @right_of_way_used || !@game.right_of_way_phase?(entity) || points_left(entity) < 1

            key = [entity.id, @round.num_laid_track, @points_used, entity.cash]
            return @right_of_way_memo[key] if @right_of_way_memo.key?(key)

            @right_of_way_memo[key] = !@game.right_of_way_connected?(entity) &&
                                      !@game.right_of_way_yellow_connection?(entity, get_tile_lay(entity), entity.cash)
          end

          def right_of_way_lay?(entity, hex, tile)
            !@game.phase.tiles.include?(tile.color) && @game.right_of_way_tile?(tile) && @game.right_of_way_hex?(hex) &&
              right_of_way_available?(entity)
          end

          def potential_tile_colors(entity, hex)
            colors = super
            return colors unless @game.right_of_way_hex?(hex) && right_of_way_available?(entity)

            colors | [:green]
          end

          # Part 2: a yellow lay in a floated RR's home hex waits for its president (Step::HomeHexConsent).
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

          def points_left(entity)
            get_tile_lay(entity) - @points_used
          end

          # §11.1.7: a double town upgraded to brown or gray needs a tile with track to all
          # usable sides of the hex. The base `TILE_UPGRADES_MUST_USE_MAX_EXITS` only knows
          # cities, so this narrows brown/gray offers on a double-town hex to the max exits.
          # Green is not restricted. (Extension, see workshop #345.)
          def upgradeable_tiles(entity_or_entities, ui_hex)
            tiles = super
            hex = @game.hex_by_id(ui_hex.id)
            return tiles unless hex.tile.cities.empty? && hex.tile.towns.size >= 2

            restricted, free = tiles.partition { |tile| %i[brown gray].include?(tile.color) }
            free + max_exits(restricted)
          end

          # Tile points a lay on this hex costs: 1 for a yellow, 2 for an upgrade,
          # doubled on a metropolis hex.
          # §15.2 (Minor B): with the ability an upgrade of a hex without a city costs 1 point; the
          # real cost of a chosen tile is `points_for_tile`, this is the cheapest it can be.
          def points_for_hex(hex, entity = nil)
            return 1 if entity && @game.minor_b?(entity) && hex.tile.color != :white && hex.tile.cities.empty? &&
                        !@game.metropolis_hex?(hex)

            base = hex.tile.color == :white ? 1 : 2
            @game.metropolis_hex?(hex) ? base * 2 : base
          end

          # Tile points a lay on `hex` costs `entity`: points_for_hex less the E/F extra point
          # (§15.5/§15.6) when a yellow lay there may use it.
          def points_for_lay(entity, hex)
            points_for_hex(hex, entity) - (ef_bonus_id(entity, hex) ? 1 : 0)
          end

          # Tile points laying `tile` costs: yellow 1, upgrade 2, metropolis tiles double; with
          # Minor B (§15.2) an upgrade to a tile without a city (towns allowed) costs 1.
          def points_for_tile(entity, tile)
            metropolis = @game.metropolis_tile?(tile)
            return metropolis ? 4 : 2 if tile.color != :yellow && (metropolis || tile.cities.any? || !@game.minor_b?(entity))
            return 1 if tile.color != :yellow

            metropolis ? 2 : 1
          end

          # §15.5/§15.6: Minor E/F (or the major holding their ability) may spend one extra tile
          # point per OR, only on a yellow tile in a hex with their terrain colour. Returns the
          # charter id whose point it would be, or nil.
          def ef_bonus_id(entity, hex, tile = nil)
            return nil unless hex.tile.color == :white && (tile.nil? || tile.color == :yellow)

            augmenters = @game.terrain_augmenters(entity, hex.tile).map(&:id)
            (augmenters & @game.ef_bonus_ids(entity)).find { |id| !@ef_bonus_used.include?(id) }
          end

          # True when only the extra point is left and some hex still takes a yellow lay with it;
          # otherwise the step ends as before instead of waiting for a pointless pass.
          def ef_bonus_lay_possible?(entity)
            return false if (@game.ef_bonus_ids(entity) - @ef_bonus_used).empty?

            @game.hexes.any? do |hex|
              ef_bonus_id(entity, hex) && tracker_available_hex(entity, hex)
            end
          end

          def can_lay_tile?(entity)
            points_available = get_tile_lay(entity) - @points_used
            return false unless points_available.positive? || ef_bonus_lay_possible?(entity)

            !entity.tokens.empty?
          end

          def get_tile_lay(entity)
            @game.tile_point_budget(entity)
          end

          def description
            tile_lay = get_tile_lay(current_entity) - @points_used
            "#{tile_lay} track points"
          end

          # A tile that settles a multi-city hex makes the corporations choose a city for the
          # tokens already standing there. Those tokens were paid for when first placed
          # (home tokens cost the track-rights price), so re-placing them is free.
          def update_token!(action, entity, tile, old_tile)
            pending = @round.pending_tokens.size
            super
            @round.pending_tokens[pending..].each { |entry| entry[:token].price = 0 }
          end

          # §11.6.4 para. 2: no paid lay that leaves the reserved 2+2 unpayable (workshop #352).
          # The patronage payout of the same lay counts against the cost.
          def pay_tile_cost!(entity_or_entities, tile, rotation, hex, spender, cost, extra_cost)
            @game.check_first_round_spend!(spender, cost, net_cost: cost - @game.patronage_payout(hex))
            super
          end

          def lay_tile_action(action)
            tile = action.tile
            old_tile = action.hex.tile
            points_available = get_tile_lay(action.entity) - @points_used
            points_cost = points_for_tile(action.entity, tile)
            bonus_id = ef_bonus_id(action.entity, action.hex, tile)
            points_cost -= 1 if bonus_id
            right_of_way = right_of_way_lay?(action.entity, action.hex, tile)
            # §11.1.9: the green tile costs all remaining tile points (at least one)
            points_cost = points_available if right_of_way
            raise GameError, 'Cannot lay an upgrade now' if tile.color != :yellow && points_cost > points_available
            raise GameError, 'Cannot lay a yellow now' if tile.color == :yellow && points_cost > points_available

            lay_tile(action)
            if right_of_way
              raise GameError, 'The Right-of-Way tile must connect the home station to another town or city' \
                unless @game.right_of_way_connected?(action.entity)

              @right_of_way_used = true
              @game.log << "#{action.entity.name} uses its Right-of-Way (§11.1.9)"
            end
            record_lay!(action.entity, action, old_tile, points_cost, bonus_id)
          end

          # Points a private's free lay (§14.9) costs the operating RR, and the E/F bonus it uses; raises
          # when the RR cannot pay them.
          def special_lay_cost(operator, hex, tile)
            bonus_id = ef_bonus_id(operator, hex, tile)
            cost = points_for_tile(operator, tile) - (bonus_id ? 1 : 0)
            raise GameError, 'Cannot lay a yellow now' if cost > points_left(operator)

            [cost, bonus_id]
          end

          # What follows a lay of `operator`: points, log, patronage and the round's lay counters.
          def record_lay!(operator, action, old_tile, points_cost, bonus_id)
            points_available = get_tile_lay(operator) - @points_used
            @ef_bonus_used << bonus_id if bonus_id
            @game.log << "Used #{points_cost} tile point(s) to lay tile#{" (+1 extra point of Minor #{bonus_id})" if bonus_id}"
            @game.log << "#{points_available - points_cost} point(s) remaining"
            @game.fulfill_patronage!(operator, action.hex)
            if track_upgrade?(old_tile, action.tile, action.hex)
              @round.upgraded_track = true
              @round.num_upgraded_track += 1
            end
            @round.num_laid_track += 1
            @round.laid_hexes << action.hex
            @points_used += points_cost
          end

          # §14.9: a token of Brandt & Brandau, Engineers on a hex closes it to this RR's trains. Another
          # RR may remove the token: it pays the hex's original terrain cost (a national only the points)
          # and one tile point (two on a metropolis), and lays no track.
          def bbe_removal_points(hex)
            @game.metropolis_hex?(hex) ? 2 : 1
          end

          def bbe_removal_money(entity, hex)
            return 0 if entity.type == :national

            @game.upgrade_cost(hex.original_tile, hex, entity, entity)
          end

          def bbe_removable_hexes(entity)
            return [] unless @game.bbe_blocked_for?(entity)

            @game.bbe_token_hexes.select { |hex| bbe_removal_points(hex) <= points_left(entity) }
          end

          def actions(entity)
            actions = super
            return actions unless entity == current_entity

            extra = []
            extra << 'remove_hex_token' unless bbe_removable_hexes(entity).empty?
            # §15.4: Minor D's token is placed in the holder's lay track step (upstream `assign`)
            extra << 'assign' if @game.green_junction_placeable?(entity)
            return actions if extra.empty?

            actions.empty? ? extra + %w[pass] : actions + extra
          end

          # §15.4: any city except a metropolis or red zone, reachable or not.
          def process_assign(action)
            entity = action.entity
            hex = action.target
            raise GameError, "#{entity.name} cannot place the Green Junction token now" unless entity == current_entity
            raise GameError, 'The Green Junction token goes on a hex' unless hex.is_a?(Engine::Hex)

            @game.green_junction_place!(entity, hex)
            pass! if actions(entity).empty?
          end

          def green_junction_hexes(entity)
            @game.green_junction_placeable?(entity) ? @game.green_junction_hexes : []
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

          def tracker_available_hex(entity, hex)
            return nil unless @game.hex_within_national_region?(entity, hex)

            connected = hex_neighbors(entity, hex)
            return nil unless connected

            points_available = get_tile_lay(entity) - @points_used
            return nil if hex.tile.color == :blue
            # §11.1.9: a president who refused the lay closes the hex to this RR for this step
            return nil if @refused_home_hexes.include?(hex)

            needed = points_for_lay(entity, hex)
            needed = 1 if needed > points_available && @game.right_of_way_hex?(hex) && right_of_way_available?(entity)
            return nil if points_available < needed

            connected
          end
        end
      end
    end
  end
end
