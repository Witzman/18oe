# frozen_string_literal: true

require_relative '../../../step/buy_train'

module Engine
  module Game
    module G18OE
      module Step
        class BuyTrain < Engine::Step::BuyTrain
          MINOR_CHARTER_VALUE = 120

          # §11.6.5: an insolvent minor/regional gets its 2+2 for free (the
          # president's cash goes into the treasury), its charter or
          # president's certificate goes to the Open Market. Resolved
          # automatically (no player decision), so the step offers no action.
          def actions(entity)
            return [] if first_round_insolvency?(current_entity)

            super
          end

          def skip!
            corporation = current_entity
            return super unless first_round_insolvency?(corporation)

            resolve_first_round_insolvency!(corporation)
            pass!
          end

          def first_round_insolvency?(corporation)
            return false unless corporation&.corporation? && %i[minor regional].include?(corporation.type)
            return false unless corporation.floated? && corporation.trains.empty? && corporation.owner&.player?
            return false if @game.fulfilled_train_obligation?(corporation)

            train = reserved_train
            !train.nil? && corporation.cash + corporation.owner.cash < train.price
          end

          def must_buy_train?(entity)
            entity.floated? && entity.trains.empty? && (!@game.fulfilled_train_obligation?(entity) || entity.type == :major)
          end

          def buyable_trains(entity)
            trains = super

            # Level 8 trains visible via available_on:'7+7' but gated until 4th L7 purchase (§11.6)
            trains = trains.reject { |t| t.name == '8+8' } unless @game.level8_train_available?

            return trains unless @game.train_obligation_active?

            if @game.fulfilled_train_obligation?(entity)
              return [] unless @game.non_starter_trains_available?

              trains.reject { |t| t.name == '2+2' }
            else
              trains.select { |t| t.name == '2+2' && t.from_depot? }
            end
          end

          def process_buy_train(action)
            reserved = action.train.name == '2+2' && action.train.from_depot?
            super
            @game.fulfill_train_obligation!(action.entity) if reserved
          end

          def reserved_train
            @game.depot.depot_trains.find { |train| train.name == '2+2' && train.from_depot? }
          end

          def resolve_first_round_insolvency!(corporation)
            player = corporation.owner
            train = reserved_train
            @log << "#{corporation.name} cannot pay for its 2+2 and #{player.name} cannot make up the difference: " \
                    'first-round insolvency'
            player.spend(player.cash, corporation) if player.cash.positive?
            @log << "#{player.name} puts all personal cash into #{corporation.name}'s treasury"

            source = train.owner
            @game.buy_train(corporation, train, :free)
            @game.phase.buying_train!(corporation, train, source)
            @game.fulfill_train_obligation!(corporation)
            @log << "#{corporation.name} receives a #{train.name} train from the Locomotive Works"

            move_certificate_to_market!(corporation, player)
          end

          def move_certificate_to_market!(corporation, player)
            face_value = corporation.type == :minor ? MINOR_CHARTER_VALUE : corporation.par_price.price * 2
            bundle = corporation.presidents_share.to_bundle
            @game.share_pool.transfer_shares(bundle, @game.share_pool, spender: @game.bank, receiver: player,
                                                                      price: face_value, allow_president_change: false)
            corporation.owner = @game.share_pool
            @log << "#{player.name} receives #{@game.format_currency(face_value)} for the #{corporation.name} " \
                    "#{corporation.type == :minor ? 'charter' : "president's certificate"}, now in the Open Market; " \
                    "#{corporation.name} will not operate until a player owns it"
          end

          # TODO: Nationals claiming rusted trains for free (openpoints §1.9, §3.7) — deferred
        end
      end
    end
  end
end
