# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18OE
      module Step
        # §11.1.9: "The home token hex of a floated RR may not have yellow track laid on it without the
        # explicit permission of the RR's president. Un-floated RRs automatically provide this permission."
        # Step::Track holds such a lay (round's pending_home_lay) and this step asks each president in
        # turn, as Step::ReserveShare interrupts a share purchase: `choose` allows, `pass` refuses. When all
        # allow, the Track step lays the tile; a refusal cancels the lay and closes the hex to this RR for
        # the rest of its lay track step.
        class HomeHexConsent < Engine::Step::Base
          CHOICE = 'allow_home_lay'

          def round_state
            super.merge(pending_home_lay: nil)
          end

          def active?
            !!@round.pending_home_lay
          end

          def blocks?
            active?
          end

          def active_entities
            active? ? [president] : []
          end

          def actions(entity)
            active? && entity == president ? %w[choose pass] : []
          end

          def choices
            { CHOICE => 'Allow' }
          end

          def choice_name
            "Allow #{layer.name} to lay yellow track in your home hex #{hex.id}?"
          end

          def description
            'Home hex permission'
          end

          def pass_description
            'Refuse'
          end

          def process_choose(action)
            raise GameError, "Unknown choice #{action.choice}" unless action.choice == CHOICE

            @log << "#{action.entity.name} allows #{layer.name} to lay yellow track in #{hex.id}"
            pending = @round.pending_home_lay
            pending[:presidents].shift
            return unless pending[:presidents].empty?

            @round.pending_home_lay = nil
            track_step.lay_with_consent!(pending[:action])
          end

          def process_pass(action)
            refused = hex
            @log << "#{action.entity.name} refuses #{layer.name} yellow track in #{refused.id}"
            @round.pending_home_lay = nil
            track_step.refuse_home_lay!(refused)
          end

          private

          def president
            @round.pending_home_lay[:presidents].first
          end

          def held
            @round.pending_home_lay[:action]
          end

          def layer
            held.entity
          end

          def hex
            held.hex
          end

          def track_step
            @round.steps.find { |step| step.is_a?(G18OE::Step::Track) }
          end
        end
      end
    end
  end
end
