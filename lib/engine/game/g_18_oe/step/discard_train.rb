# frozen_string_literal: true

require_relative '../../../step/discard_train'

module Engine
  module Game
    module G18OE
      module Step
        # A national over its train limit may hold rusted trains (§9.4). A rusted train it discards
        # is not offered in the Open Market (rusted trains may be acquired only by nationals,
        # §2.2.1); it leaves the national like any rusting train. Other trains: the engine's rule.
        class DiscardTrain < Engine::Step::DiscardTrain
          # §14.10: the preserved 2+2 does not count against the limit, so it is never the one to go
          def trains(corporation)
            super.reject { |train| @game.sml_train?(train) }
          end

          def process_discard_train(action)
            train = action.train
            return super unless train.rusted

            @game.rust(train)
            @log << "#{action.entity.name} discards its rusted #{train.name}"
          end
        end
      end
    end
  end
end
