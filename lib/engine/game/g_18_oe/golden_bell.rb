# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # Minor C (Golden Bell Marketplace), rulebook 15.6 (p. 45): the president of an un-merged
      # Minor C may choose to operate it first, last or in its normal position among the regionals
      # and minors; the president of a major that owns Minor C may choose the same for the major
      # among the majors and nationals. The choice is made at the start of each OR (Step::GoldenBellOrder)
      # and holds for that OR only.
      #
      # Assumption (rulebook: "first, last, or in its normal position"; issue #70 says the same):
      # three options, "normal" being the default and the same as making no choice.
      module GoldenBell
        GOLDEN_BELL_ID = 'C'

        # The operating entity the choice is about: Minor C while it is a floated, player-owned
        # minor, else the major (or national) that merged it.
        def golden_bell_holder
          minor = corporation_by_id(GOLDEN_BELL_ID)
          return unless minor

          return minor if minor.floated? && !minor.closed? && !minor.receivership? && minor.owner&.player?

          major = @merged_minors.find { |_, minors| minors.include?(minor) }&.first
          major if major&.floated? && !major.closed? && major.owner&.player?
        end

        def golden_bell_chooser
          golden_bell_holder&.owner
        end

        def golden_bell_pending?
          !!@golden_bell_pending
        end

        def golden_bell_position
          @golden_bell_position || :normal
        end

        # Called when an OR is created: the choice of the previous OR is void.
        def golden_bell_reset!
          @golden_bell_position = nil
          @golden_bell_pending = false
        end

        def golden_bell_ask!
          @golden_bell_pending = !golden_bell_chooser.nil?
        end

        def golden_bell_choose!(position)
          @golden_bell_position = position
          @golden_bell_pending = false
        end

        # Moves the holder to the front or back of its own group (minors/regionals or majors/nationals).
        def golden_bell_order(minors_and_regionals, majors_and_nationals)
          holder = golden_bell_holder
          position = golden_bell_position
          return minors_and_regionals + majors_and_nationals if holder.nil? || position == :normal

          group = holder.type == :minor ? minors_and_regionals : majors_and_nationals
          if group.delete(holder)
            position == :first ? group.unshift(holder) : group.push(holder)
          end
          minors_and_regionals + majors_and_nationals
        end
      end
    end
  end
end
