# frozen_string_literal: true

require_relative '../../../step/bankrupt'

module Engine
  module Game
    module G18OE
      module Step
        # §11.6.4: a major that must buy a train and whose treasury plus president's cash cannot pay
        # the cheapest one is not bankrupt (and the game does not end): its president's private cash
        # goes to the bank and the major becomes a national (Game#form_national!, §9.4). The action
        # keeps the engine's name `bankrupt`; the generic step would declare the player bankrupt.
        class Bankrupt < Engine::Step::Bankrupt
          def actions(entity)
            return [] unless entity == current_entity && entity.corporation? && entity.owner&.player?
            return [] unless @round.active_step.is_a?(G18OE::Step::BuyTrain)
            return [] unless @game.can_go_bankrupt?(entity.owner, entity)

            super
          end

          def description
            'Convert to National'
          end

          def help
            'The treasury and the president\'s cash cannot pay for the cheapest train (§11.6.4): ' \
              'the president\'s cash goes to the bank and the major becomes a national.'
          end

          def process_bankrupt(action)
            corporation = action.entity
            player = corporation.owner
            raise GameError, "#{corporation.name} can pay for a train, it cannot convert to a national" unless
              @game.can_go_bankrupt?(player, corporation)

            if player.cash.positive?
              @log << "#{player.name} pays all personal cash (#{@game.format_currency(player.cash)}) into the bank"
              player.spend(player.cash, @game.bank)
            end
            @game.form_national!(corporation)
          end
        end
      end
    end
  end
end
