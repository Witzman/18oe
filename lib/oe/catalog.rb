# frozen_string_literal: true

require "json"
require "engine"

module Oe
  # The static catalog of the game's cards (#124): privates, minors, concessions
  # and regionals with name, ability text, income, home hex, token prices and
  # colours. Read from the engine's entity tables (`entities.rb`), never typed
  # in again; texts stay English exactly as the engine has them (G8). Nothing
  # in here changes during a game: who owns what, and whether an ability is
  # used, is `companies` in the game state (Oe::View).
  #
  #   Oe::Catalog.build  # => {privates: [...10], minors: [...12], concessions: [...10], regionals: [...24]}
  module Catalog
    SCHEMA = 1

    module_function

    def build
      game = Engine::Game::G18OE::Game
      minor_ids = game::CORPORATIONS.select { |c| c[:type].to_s == "minor" }.map { |c| c[:sym] }
      cards = game::COMPANIES.group_by do |c|
        if c[:type] == :concession then :concessions
        elsif minor_ids.include?(c[:sym]) then :minors
        else :privates
        end
      end
      charters = cards.fetch(:minors).to_h { |c| [c[:sym], c] }

      {
        privates: cards.fetch(:privates).map { |c| card(c) },
        minors: game::CORPORATIONS.select { |c| c[:type].to_s == "minor" }.map { |c| minor(c, charters.fetch(c[:sym])) },
        concessions: cards.fetch(:concessions).map { |c| card(c) },
        regionals: game::CORPORATIONS.select { |c| c[:type].to_s == "regional" }.map { |c| regional(game, c) },
      }
    end

    def json
      @json ||= JSON.generate(schema: SCHEMA, **build)
    end

    # A private or concession card: `text` is the ability text of the rulebook
    # card, `abilities` the engine's ability types (for the client's markers).
    def card(company)
      {
        id: company[:sym],
        name: company[:name],
        value: company[:value],
        revenue: company[:revenue],
        text: company[:desc],
        auction_row: company[:auction_row],
        abilities: Array(company[:abilities]).map { |a| a[:type].to_s },
      }
    end

    # A minor: the corporation (colours, token prices) and the charter private
    # it is bought as in the auction.
    def minor(corp, charter)
      {
        id: corp[:sym],
        name: corp[:name],
        color: corp[:color],
        text_color: corp[:text_color],
        token_prices: corp[:tokens],
        text: ability_text(corp),
        charter: card(charter),
      }
    end

    def regional(game, corp)
      {
        id: corp[:sym],
        name: corp[:name],
        home: corp[:coordinates],
        zone: game::CORPORATIONS_TRACK_RIGHTS[corp[:sym]],
        color: corp[:color],
        text_color: corp[:text_color],
        token_prices: corp[:tokens],
        shares: corp[:shares],
        float_percent: corp[:float_percent],
        text: ability_text(corp),
      }
    end

    def ability_text(corp)
      Array(corp[:abilities]).filter_map { |a| a[:description] }.join(" ")
    end
  end
end
