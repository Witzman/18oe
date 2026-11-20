# frozen_string_literal: true

require_relative 'base'
require_relative '../helper/trade_objects'

module Engine
  module Action
    class BuyCorporation < Base
      include Helper::TradeObjects

      attr_reader :entity, :corporation, :minor, :price

      REQUIRED_ARGS = %i[price].freeze

      def initialize(entity, price:, corporation: nil, minor: nil, give: [], also: [])
        super(entity)
        @give = give
        @also = also
        @corporation = corporation
        @minor = minor
        @price = price
      end

      def self.h_to_args(h, game)
        {
          corporation: game.corporation_by_id(h['corporation']),
          minor: game.minor_by_id(h['minor']),
          price: h['price'],
        }.merge(trade_objects_from_h(h, game))
      end

      def args_to_h
        {
          'corporation' => @corporation&.id,
          'minor' => @minor&.id,
          'price' => @price,
        }.merge(trade_objects_to_h)
      end
    end
  end
end
