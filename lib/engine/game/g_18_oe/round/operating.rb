# frozen_string_literal: true

require_relative '../../../round/operating'

module Engine
  module Round
    module G18OE
      class Operating < Engine::Round::Operating
        # §11.6.5: a minor/regional whose certificate sits in the Open Market does not operate.
        def skip_entity?(entity)
          super || (%i[minor regional].include?(entity.type) && entity.receivership?)
        end
      end
    end
  end
end
