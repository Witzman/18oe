# frozen_string_literal: true

module Engine
  module Action
    # §10.4 (#517): the objects of a player trade besides the target and the cash price. `give` are the
    # buyer's own minors / face up privates, `also` further ones of the seller. Written to the action
    # hash only when there are some, so every action recorded before stays as it was.
    module TradeObjects
      def self.included(klass)
        klass.extend(ClassMethods)
      end

      module ClassMethods
        def trade_objects_from_h(h, game)
          {
            give: Array(h['give']).map { |type, id| game.get(type, id) }.compact,
            also: Array(h['also']).map { |type, id| game.get(type, id) }.compact,
          }
        end
      end

      attr_reader :give, :also

      def trade_objects_to_h
        { 'give' => @give, 'also' => @also }.reject { |_, list| list.empty? }
                                              .transform_values { |list| list.map { |obj| [type_s(obj), obj.id] } }
      end
    end
  end
end
