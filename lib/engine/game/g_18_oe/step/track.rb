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
          end

          attr_reader :points_used

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
          def points_for_hex(hex)
            base = hex.tile.color == :white ? 1 : 2
            @game.metropolis_hex?(hex) ? base * 2 : base
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
            metropolis = @game.metropolis_tile?(tile)
            points_available = get_tile_lay(action.entity) - @points_used
            points_cost = if tile.color != :yellow && metropolis
                            4
                          elsif (tile.color == :yellow && metropolis) || tile.color != :yellow
                            2
                          else
                            1
                          end
            bonus_id = ef_bonus_id(action.entity, action.hex, tile)
            points_cost -= 1 if bonus_id
            raise GameError, 'Cannot lay an upgrade now' if tile.color != :yellow && points_cost > points_available
            raise GameError, 'Cannot lay a yellow now' if tile.color == :yellow && points_cost > points_available

            lay_tile(action)
            @ef_bonus_used << bonus_id if bonus_id
            @game.log << "Used #{points_cost} tile point(s) to lay tile#{" (+1 extra point of Minor #{bonus_id})" if bonus_id}"
            @game.log << "#{points_available - points_cost} point(s) remaining"
            @game.fulfill_patronage!(action.entity, action.hex)
            if track_upgrade?(old_tile, tile, action.hex)
              @round.upgraded_track = true
              @round.num_upgraded_track += 1
            end
            @round.num_laid_track += 1
            @round.laid_hexes << action.hex
            @points_used += points_cost
          end

          def tracker_available_hex(entity, hex)
            return nil unless @game.hex_within_national_region?(entity, hex)

            connected = hex_neighbors(entity, hex)
            return nil unless connected

            points_available = get_tile_lay(entity) - @points_used
            return nil if hex.tile.color == :blue

            needed = points_for_hex(hex) - (ef_bonus_id(entity, hex) ? 1 : 0)
            return nil if points_available < needed

            connected
          end
        end
      end
    end
  end
end
