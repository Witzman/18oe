# frozen_string_literal: true

require_relative '../../../step/special_choose'

module Engine
  module Game
    module G18OE
      module Step
        class SpecialChoose < Engine::Step::SpecialChoose
          # RB 14.4 (1) in the OR: the choices of Barclay, Bevan, Barclay and Tritton are the other par values of the
          # operating RR, so the private acts only while it has some.
          def actions(entity)
            return super unless entity == @game.bbbt_company

            choices_ability(entity).empty? ? [] : super
          end

          def choices_ability(entity)
            return super unless entity == @game.bbbt_company

            operator = @round.current_operator
            return {} unless operator&.corporation?

            @game.bbbt_repar_cells(entity, operator).to_h do |cell|
              ["#{Bbbt::BBBT_REPAR}:#{cell.price}", "Re-Par #{operator.name}: #{@game.format_currency(cell.price)}"]
            end
          end

          def process_choose_ability(action)
            company = action.entity
            if company == @game.bbbt_company
              raise GameError, "Unknown choice #{action.choice}" unless choices_ability(company).key?(action.choice)

              return @game.bbbt_repar_now!(company, @round.current_operator, action.choice.split(':', 2).last.to_i)
            end

            @game.acquire_swift_metropolitan_train!(@round.current_operator)
            @game.remove_private!(action.entity)
          end
        end
      end
    end
  end
end
