# frozen_string_literal: true

require_relative '../../../step/special_track'

module Engine
  module Game
    module G18OE
      module Step
        # RB 14.9 Brandt & Brandau, Engineers: in the Track step of a RR of its owner the private places one of its tokens on
        # a rough hex and lays a yellow tile there at no terrain cost. The lay spends the operating RR's tile points
        # (Track#record_special_lay!); the tile_lay ability gives the count (4, two per OR), the hexes and the free lay.
        class SpecialTrack < Engine::Step::SpecialTrack
          ACTIONS = %w[lay_tile].freeze

          def actions(entity)
            return [] unless entity.company? && abilities(entity) && entity.owner == operator.owner
            return [] if track_step.nil? || track_step.tile_points_left(operator) < 1

            ACTIONS
          end

          def available_hex(entity, hex)
            return unless (ability = abilities(entity))
            return unless ability.hexes.include?(hex.id) && hex.tile.color == :white
            return unless track_step.tile_points_left(operator) >= @game.tile_point_cost(operator, old_tile: hex.tile)

            track_step.tracker_available_hex(operator, hex)
          end

          def hex_neighbors(entity, hex)
            return unless abilities(entity)

            track_step.hex_neighbors(operator, hex)
          end

          def process_lay_tile(action)
            company = action.entity
            ability = abilities(company)
            raise GameError, "#{company.name} cannot lay a tile now" unless ability
            raise GameError, "#{action.hex.id} cannot be built on now" unless available_hex(company, action.hex)

            old_tile = action.hex.tile
            points_cost = @game.tile_point_cost(operator, old_tile: old_tile)
            lay_tile(action, spender: operator)
            ability.use!
            track_step.record_special_lay!(operator, action, old_tile, points_cost)
            @game.bbe_place_token!(action.hex, company)
            track_step.pass! unless track_step.can_lay_tile?(operator)
          end

          private

          def operator
            @game.current_entity
          end

          def track_step
            @round.steps.find { |step| step.is_a?(G18OE::Step::Track) }
          end
        end
      end
    end
  end
end
