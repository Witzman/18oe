# frozen_string_literal: true

require_relative 'base'

module Engine
  module Action
    class PlaceToken < Base
      attr_reader :city, :slot
      attr_accessor :cost, :token

      REQUIRED_ARGS = %i[city].freeze

      def initialize(entity, city:, slot: nil, cost: nil, tokener: nil, token_type: nil, token_index: nil)
        super(entity)
        @city = city
        @slot = slot
        # Cost is optional; if present this overrides the normal cost of the token
        @cost = cost
        @tokener = tokener
        # token may be nil because when you upgrade someone's 00
        # and place their token, you pretend to be them and you may not have a token
        token_owner = @tokener || (@entity.company? ? @entity.owner : @entity)
        @token = token_owner.find_token_by_type(token_type&.to_sym)
        @token_owner = token_owner
        # Free choice of an available token on the charter (18OE rules 11.2): an
        # index into the owner's token row. Absent in old logs, which keep
        # taking the first unused token of the type.
        @token = token_owner.tokens[token_index] if token_index && token_owner.tokens[token_index]
      end

      def self.h_to_args(h, game)
        {
          city: game.city_by_id(h['city']),
          slot: h['slot'],
          cost: h['cost'],
          tokener: game.corporation_by_id(h['tokener']) || game.minor_by_id(h['tokener']),
          token_type: h['token_type'],
          token_index: h['token_index'],
        }
      end

      def args_to_h
        {
          'city' => @city.id,
          'slot' => @slot,
          'cost' => @cost,
          'tokener' => @tokener&.id,
          'token_type' => @token&.type == :normal ? nil : @token&.type,
          'token_index' => token_index_to_h,
        }
      end

      private

      # Written only when the token differs from the default pick (first unused
      # token of its type), so logs of ordinary placements stay byte-identical.
      def token_index_to_h
        return unless @token && @token_owner

        default = @token_owner.find_token_by_type(@token.type == :normal ? nil : @token.type)
        return if default.equal?(@token)

        @token_owner.tokens.index(@token)
      end
    end
  end
end
