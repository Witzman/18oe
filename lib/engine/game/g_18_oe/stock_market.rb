# frozen_string_literal: true

require_relative '../../stock_market'

module Engine
  module Game
    module G18OE
      class StockMarket < Engine::StockMarket
        # §4.4 UP: where no field lies above (top row, or the stepped left edge of the board: arrow RIGHT) the
        # marker moves RIGHT in its row.
        def up(corporation, coordinates)
          r, c = coordinates
          return super if r.positive? && share_price([r - 1, c])

          share_price([r, c + 1]) ? [r, c + 1] : coordinates
        end
      end
    end
  end
end
