# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # Transfer Tokens (§11.5), workshop #57: step 5 of a major's OR turn. A major buys a placed station token of
      # another major of the same player (never a home token): it pays the bank the placement cost of its own next
      # charter token and the selling major the access fee of the city, its token replaces the seller's, and the
      # replaced token goes back to the seller's highest-cost open charter position.
      module TokenTransfer
        TOKEN_TRANSFER_FEES = { city: 20, grand: 40, metropolis: 60 }.freeze
        TOKEN_TRANSFER_PREFIX = 'transfer_token:'

        # §11.5 table: normal city £20, grand city ("Y" tile) £40, metropolis £60.
        def token_transfer_fee(hex)
          return TOKEN_TRANSFER_FEES[:metropolis] if metropolis_hex?(hex) || metropolis_tile?(hex.tile)
          return TOKEN_TRANSFER_FEES[:grand] if hex.tile.label.to_s == 'Y'

          TOKEN_TRANSFER_FEES[:city]
        end

        # The choices (id => label) the buying major may take now: "transfer_token:<seller>:<hex>:<city index>".
        def token_transfer_choices(buyer)
          return {} unless buyer&.corporation? && buyer.type == :major && buyer.floated? && !buyer.closed?

          own = buyer.next_token
          return {} unless own

          token_transfer_candidates(buyer).each_with_object({}) do |token, choices|
            city = token.city
            fee = token_transfer_fee(city.tile.hex)
            next if buyer.cash < own.price + fee

            choices[token_transfer_choice_id(token)] =
              "Buy #{token.corporation.name}'s token in #{token_transfer_place(city)} " \
              "(#{format_currency(own.price)} to the bank, #{format_currency(fee)} to #{token.corporation.name})"
          end
        end

        def token_transfer_choice?(choice)
          choice.to_s.start_with?(TOKEN_TRANSFER_PREFIX)
        end

        def transfer_token!(buyer, choice)
          raise GameError, "#{choice} is not a token #{buyer.name} may buy (§11.5)" unless
            token_transfer_choices(buyer).key?(choice)

          _, seller_id, hex_id, index = choice.split(':')
          seller = corporation_by_id(seller_id)
          city = hex_by_id(hex_id).tile.cities[index.to_i]
          token = city.tokens.find { |t| t&.corporation == seller }
          own = buyer.next_token
          fee = token_transfer_fee(city.tile.hex)

          buyer.spend(own.price, @bank) if own.price.positive?
          buyer.spend(fee, seller)
          token.remove!
          city.exchange_token(own)
          token_transfer_return!(seller, token)
          graph.clear
          @log << "#{buyer.name} buys #{seller.name}'s token in #{token_transfer_place(city)} for " \
                  "#{format_currency(own.price)} to the bank and #{format_currency(fee)} to #{seller.name} (§11.5)"
        end

        private

        def token_transfer_candidates(buyer)
          @corporations.select { |c| c != buyer && c.type == :major && c.floated? && !c.closed? && c.owner == buyer.owner }
                       .flat_map { |seller| token_transfer_tokens(seller) }
                       .reject { |token| buyer_has_token_in?(buyer, token.city) }
        end

        # Placed tokens of a major that may be sold: standing in a city slot, no home token, no pass-through token.
        def token_transfer_tokens(seller)
          home = seller.tokens.first
          seller.placed_tokens.select do |token|
            token != home && token.type == :normal && !pass_token?(token) && token.city&.tokens&.include?(token)
          end
        end

        def buyer_has_token_in?(buyer, city)
          (city.tokens + city.extra_tokens).any? { |t| t&.corporation == buyer }
        end

        def token_transfer_choice_id(token)
          city = token.city
          "#{TOKEN_TRANSFER_PREFIX}#{token.corporation.id}:#{city.tile.hex.id}:#{city.index}"
        end

        def token_transfer_place(city)
          hex = city.tile.hex
          hex.tile.cities.size > 1 ? "#{hex.name} city #{city.index}" : hex.name
        end

        # §11.5: the replaced token goes back to the seller's highest-cost open charter position. Open positions
        # are filled lowest first, so the unplaced tokens now take the highest prices of the charter.
        def token_transfer_return!(seller, token)
          prices = seller.tokens.reject { |t| t == seller.tokens.first }.map(&:price).sort
          unplaced = seller.unplaced_tokens.reject { |t| t == seller.tokens.first }
          unplaced.zip(prices.last(unplaced.size)).each { |t, price| t.price = price }
          token.used = false
        end
      end
    end
  end
end
