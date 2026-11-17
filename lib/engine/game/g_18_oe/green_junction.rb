# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # Minor D (Green Junction Mercantile), rulebook 15.4 (p. 45): the minor's token, placed in any city on
      # the map except a metropolis or a red zone (even one the RR cannot run to), adds £20 to the trains of
      # the minor, or of the major it merges into, run to or through that city in Train Phase 2-4. At the
      # beginning of Phase 5 that token is removed; then or later a £40 token may be placed in the same or
      # another city. The token is placed in the RR's lay track step and may be delayed. §11.3.9: "D" trains
      # double it. §9.5: when the minor is abandoned its tokens go back to the charter.
      #
      # The token is the upstream hex assignment (Engine::Assignable, as 1846's Steamboat/Meat Packing
      # markers), placed with the upstream `assign` action in G18OE::Step::Track. The holder is whoever holds
      # the charter's ability object: it moves to the major on a merge (Game#add_minor_charter!).
      #
      # A major that converts to a national abandons the merged minor (§9.4 step 3): the token and the
      # ability go back to the D charter (Game#abandon_merged_minor!).
      module GreenJunction
        GREEN_JUNCTION_ID = 'D'
        GREEN_JUNCTION_LATE_PHASE = 5
        GREEN_JUNCTION_BONUS = { early: 20, late: 40 }.freeze

        attr_reader :green_junction_hex

        def setup_green_junction!
          @green_junction_ability = corporation_by_id(GREEN_JUNCTION_ID)&.abilities&.first
          @green_junction_hex = nil
          @green_junction_value = nil
          @green_junction_placed = []
        end

        def green_junction_holder?(entity)
          !@green_junction_ability.nil? && entity.respond_to?(:abilities) &&
            entity.abilities.include?(@green_junction_ability)
        end

        # The value of a token placed now: £20 in Phase 2-4, £40 from Phase 5.
        def green_junction_bonus
          late = @phase.name.to_i >= GREEN_JUNCTION_LATE_PHASE
          GREEN_JUNCTION_BONUS[late ? :late : :early]
        end

        def green_junction_city?(hex)
          !hex.tile.cities.empty? && hex.tile.color != :red && !metropolis_hex?(hex)
        end

        def green_junction_hexes
          hexes.select { |hex| green_junction_city?(hex) }
        end

        # One £20 token for Phase 2-4, one £40 token from Phase 5; neither while a token is on the map.
        def green_junction_placeable?(entity)
          green_junction_holder?(entity) && @green_junction_hex.nil? &&
            !@green_junction_placed.include?(green_junction_bonus)
        end

        def green_junction_place!(entity, hex)
          raise GameError, "#{entity.name} cannot place the Green Junction token now" unless green_junction_placeable?(entity)
          raise GameError, "#{hex.id} cannot take the Green Junction token" unless green_junction_city?(hex)

          @green_junction_value = green_junction_bonus
          @green_junction_placed << @green_junction_value
          @green_junction_hex = hex
          hex.assign!(GREEN_JUNCTION_ID)
          @log << "#{entity.name} places the Green Junction token " \
                  "(+#{format_currency(@green_junction_value)}) in #{hex.location_name || hex.id}"
        end

        # Takes the token off the map; with `back_to_charter` it may be placed again (§9.5).
        def green_junction_remove!(back_to_charter: false)
          return unless @green_junction_hex

          @green_junction_hex.remove_assignment!(GREEN_JUNCTION_ID)
          @green_junction_placed.delete(@green_junction_value) if back_to_charter
          @log << "Green Junction token (+#{format_currency(@green_junction_value)}) removed from " \
                  "#{@green_junction_hex.location_name || @green_junction_hex.id}"
          @green_junction_hex = nil
          @green_junction_value = nil
        end

        # Bonus of one train's route: the token's value if the train belongs to the holder and its route
        # runs to or through the token's city; doubled by a "D" train's multiplier (§11.3.9).
        def green_junction_revenue(route)
          return 0 unless @green_junction_hex && green_junction_holder?(route.train.owner)
          return 0 unless route.visited_stops.any? { |stop| stop.city? && stop.hex == @green_junction_hex }

          @green_junction_value * (route.train.multiplier || 1)
        end

        # §15.4: "At the beginning of Train Phase 5, the '+£20' token is removed from the Map."
        def green_junction_phase_change!
          return unless @green_junction_hex && @green_junction_value == GREEN_JUNCTION_BONUS[:early]
          return if @phase.name.to_i < GREEN_JUNCTION_LATE_PHASE

          green_junction_remove!
        end
      end
    end
  end
end
