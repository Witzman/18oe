# frozen_string_literal: true

require_relative '../../../step/base'
require_relative '../../../action/convert'

module Engine
  module Game
    module G18OE
      module Step
        # §9.4: when the first train of Train Phase 4, 6 or 8 is bought, each player in turn
        # (beginning with the player whose railroad bought it, then in player order) may convert
        # one or more of their majors into nationals. The player passes when done.
        #
        # Same shape as the regional conversion of the stock round (BuySellParShares): the
        # step waits for a player, the `convert` action is issued by the corporation
        # (Engine::Action::Convert), `pass` by the player. The formation itself is
        # Game#form_national!; the trigger is Game#rust_trains!, which knows the buyer.
        class ConvertToNational < Engine::Step::Base
          def actions(entity)
            player = current_entity
            return [] unless player
            return ['pass'] if entity == player
            return ['convert'] if can_convert?(entity, player)

            []
          end

          def active?
            !current_entity.nil?
          end

          def active_entities
            player = current_entity
            player ? [player] : []
          end

          def current_entity
            @game.national_formation_player
          end

          # Used by Oe::LegalActions#generate_convert, as for the regional conversion.
          def can_convert?(corporation, player)
            corporation&.corporation? && @game.national_candidates(player).include?(corporation)
          end

          def description
            'Form Nationals'
          end

          def help
            player = current_entity
            return '' unless player

            majors = @game.national_candidates(player).map(&:name).join(', ')
            "Train Phase #{@game.national_formation[:phase]} began: nationals may form (§9.4). " \
              "#{player.name} may convert any of #{majors} into a national. A national's cash goes to the bank, " \
              "its treasury shares go to the Open Market, all its tokens leave the map; it keeps its trains, " \
              'including the ones rusting now.'
          end

          def pass_description
            'Done (keep the rest as majors)'
          end

          def process_convert(action)
            corporation = action.entity
            player = current_entity
            raise GameError, "#{corporation.name} cannot form a national now" unless can_convert?(corporation, player)

            @game.form_national!(corporation)
          end

          def process_pass(action)
            player = current_entity
            raise GameError, "#{action.entity.name} is not forming nationals now" unless action.entity == player

            @log << "#{player.name} forms no more nationals"
            @game.national_formation_done!(player)
          end

          # The step is active only while a player may convert; never passed or skipped as a whole.
          def skip!; end
        end
      end
    end
  end
end
