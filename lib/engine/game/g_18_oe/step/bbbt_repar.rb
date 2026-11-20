# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18OE
      module Step
        # §14.4 (1) (#513): the owner of Barclay, Bevan, Barclay and Tritton may re-set the par value of the RR
        # operating "during the RR's OR", when the owner owns it and it still has its par value marker. The private
        # acts as its own entity through the upstream `choose` action (as Step::SmlTrain); the RR is the operator.
        class BbbtRepar < Engine::Step::Base
          ACTIONS = %w[choose].freeze

          def actions(entity)
            usable?(entity) ? ACTIONS : []
          end

          def blocks?
            false
          end

          def choices
            company = @game.bbbt_company
            operator = @game.current_entity
            return {} unless company && operator&.corporation?

            @game.bbbt_repar_cells(company, operator).to_h do |cell|
              ["#{Bbbt::BBBT_REPAR}:#{cell.price}", "Re-Par #{operator.name}: #{@game.format_currency(cell.price)}"]
            end
          end

          def choice_name
            "Re-Par #{@game.current_entity.name} (#{@game.bbbt_company.name})"
          end

          def process_choose(action)
            company = action.entity
            raise GameError, "#{company.name} cannot re-set a par value now" unless usable?(company)
            raise GameError, "Unknown choice #{action.choice}" unless choices.key?(action.choice)

            @game.bbbt_repar_now!(company, @game.current_entity, action.choice.split(':', 2).last.to_i)
          end

          private

          def usable?(entity)
            entity.company? && entity == @game.bbbt_company && !choices.empty?
          end
        end
      end
    end
  end
end
