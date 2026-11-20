# frozen_string_literal: true

require_relative 'base'
require_relative '../helper/trade_objects'

module Engine
  module Action
    class BuyCompany < Base
      include Helper::TradeObjects

      attr_reader :entity, :company, :price

      REQUIRED_ARGS = %i[company price].freeze

      def initialize(entity, company:, price:, give: [], also: [])
        super(entity)
        @give = give
        @also = also
        @company = company
        @price = price
      end

      def self.h_to_args(h, game)
        {
          company: game.company_by_id(h['company']),
          price: h['price'],
        }.merge(trade_objects_from_h(h, game))
      end

      def args_to_h
        {
          'company' => @company.id,
          'price' => @price,
        }.merge(trade_objects_to_h)
      end
    end
  end
end
