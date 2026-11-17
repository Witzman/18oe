# frozen_string_literal: true

require_relative '../../../step/special_track'

module Engine
  module Game
    module G18OE
      module Step
        # §14.9 Brandt & Brandau, Engineers: while the owner's RR lays track, the private places one of
        # its tokens on a rough hex and lays a yellow tile there at no terrain cost. The lay spends the
        # operating RR's tile points (so it is checked and recorded by the Track step); the upstream
        # tile_lay ability gives the count (4, two per OR), the hexes and the free lay.
        class SpecialTrack < Engine::Step::SpecialTrack
          ACTIONS = %w[lay_tile].freeze

          def actions(entity)
            return [] unless entity.company? && abilities(entity)
            return [] if track_step.nil? || track_step.points_left(operator).zero? && !track_step.ef_bonus_lay_possible?(operator)

            ACTIONS
          end

          def available_hex(entity, hex)
            return unless (ability = abilities(entity))
            return unless ability.hexes.include?(hex.id)

            track_step.tracker_available_hex(operator, hex)
          end

          def hex_neighbors(entity, hex)
            return unless abilities(entity)

            track_step.hex_neighbors(operator, hex)
          end

          def check_track_restrictions!(_entity, old_tile, new_tile)
            super(operator, old_tile, new_tile)
          end

          def process_lay_tile(action)
            company = action.entity
            ability = abilities(company)
            raise GameError, "#{company.name} cannot lay a tile now" unless ability
            raise GameError, "#{action.hex.id} cannot be built on now" unless available_hex(company, action.hex)

            old_tile = action.hex.tile
            cost, bonus_id = track_step.special_lay_cost(operator, action.hex, action.tile)
            lay_tile(action, spender: operator)
            ability.use!
            track_step.record_lay!(operator, action, old_tile, cost, bonus_id)
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
