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
          end

          attr_reader :points_used

          def points_left(entity)
            get_tile_lay(entity) - @points_used
          end

          # Tile points a lay on this hex costs: 1 for a yellow, 2 for an upgrade,
          # doubled on a metropolis hex.
          def points_for_hex(hex)
            base = hex.tile.color == :white ? 1 : 2
            @game.metropolis_hex?(hex) ? base * 2 : base
          end

          def can_lay_tile?(entity)
            points_available = get_tile_lay(entity) - @points_used
            return false unless points_available.positive?

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
            raise GameError, 'Cannot lay an upgrade now' if tile.color != :yellow && points_cost > points_available
            raise GameError, 'Cannot lay a yellow now' if tile.color == :yellow && points_cost > points_available

            lay_tile(action)
            @game.log << "Used #{points_cost} tile point(s) to lay tile"
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
            return nil if points_available < points_for_hex(hex)

            connected
          end
        end
      end
    end
  end
end
