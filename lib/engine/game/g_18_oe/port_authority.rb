# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # Port authority markers (§11.3.5), workshop #56, part 1: ownership. A major buys one marker for £125 at any
      # time before the Buy Trains step of its OR turn (offered as a `choose` in the Track, Token and Route steps);
      # one marker per major, eight North Sea and eight Mediterranean markers from the start. The effect on city
      # limit and cross-water cost follows in the next parts. A marker is lost when its major becomes a national.
      module PortAuthority
        PORT_AUTHORITY_PRICE = 125
        PORT_AUTHORITY_AREAS = { north_sea: 'North Sea', mediterranean: 'Mediterranean' }.freeze
        PORT_AUTHORITY_PER_AREA = 8

        attr_reader :port_authority_supply

        def setup_port_authorities!
          @port_authority_owners = {}
          @port_authority_supply = PORT_AUTHORITY_AREAS.keys.to_h { |area| [area, PORT_AUTHORITY_PER_AREA] }
        end

        def port_authority(corporation)
          @port_authority_owners[corporation]
        end

        # The choices (id => label) a major may take now; empty for anyone else.
        def port_authority_choices(entity)
          return {} unless entity&.corporation? && entity.type == :major && !port_authority(entity)

          PORT_AUTHORITY_AREAS.each_with_object({}) do |(area, name), choices|
            next if @port_authority_supply[area].zero? || entity.cash < PORT_AUTHORITY_PRICE

            choices["port_authority:#{area}"] = "Buy the #{name} port authority marker (#{format_currency(PORT_AUTHORITY_PRICE)})"
          end
        end

        def port_authority_choice?(choice)
          choice.to_s.start_with?('port_authority:')
        end

        def buy_port_authority!(entity, choice)
          raise GameError, "#{choice} is not a port authority marker #{entity.name} may buy (§11.3.5)" unless
            port_authority_choices(entity).key?(choice)

          area = choice.delete_prefix('port_authority:').to_sym
          entity.spend(PORT_AUTHORITY_PRICE, @bank)
          @port_authority_supply[area] -= 1
          @port_authority_owners[entity] = area
          @log << "#{entity.name} buys the #{PORT_AUTHORITY_AREAS[area]} port authority marker " \
                  "for #{format_currency(PORT_AUTHORITY_PRICE)}"
        end

        # A national owns no marker: it goes back to its supply.
        def port_authority_off!(corporation)
          area = @port_authority_owners.delete(corporation)
          return unless area

          @port_authority_supply[area] += 1
          @log << "#{corporation.name}'s #{PORT_AUTHORITY_AREAS[area]} port authority marker goes back to the supply"
        end
      end
    end
  end
end
