# frozen_string_literal: true

require_relative '../../../step/buy_train'
require_relative 'skip_abbreviated_round'

module Engine
  module Game
    module G18OE
      module Step
        class BuyTrain < Engine::Step::BuyTrain
          include SkipAbbreviatedRound

          MINOR_CHARTER_VALUE = 120

          def actions(entity)
            return [] if first_round_insolvency?(current_entity)

            actions = super - ['sell_shares']
            actions += ['choose'] if entity == current_entity && @game.forced_national_conversion?(entity)
            actions
          end

          def can_sell?(_entity, _bundle)
            false
          end

          # RB 11.6.5: a minor or regional that must force buy its reserved 2+2 while treasury and president together
          # cannot pay gets the train for free (the president's cash goes into the treasury) and its charter or
          # president's certificate goes to the Open Market. Resolved by the step itself, no player decision.
          def skip!
            corporation = current_entity
            return super unless first_round_insolvency?(corporation)

            resolve_first_round_insolvency!(corporation)
            pass!
          end

          def first_round_insolvency?(corporation)
            return false unless corporation&.corporation? && %i[minor regional].include?(corporation.type)
            return false unless corporation.floated? && @game.trainless?(corporation) && corporation.owner&.player?
            return false if @game.fulfilled_train_obligation?(corporation)

            train = reserved_train
            !train.nil? && corporation.cash + corporation.owner.cash < train.price
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

          def show_president_contributions?(entity, shell = nil)
            super && !@game.forced_national_conversion?(entity)
          end

          def choice_name
            shortfall = @game.format_currency(@game.forced_train_price(current_entity) - current_entity.cash)
            "#{current_entity.owner.name} cannot cover #{current_entity.name}'s #{shortfall} shortfall for the cheapest train"
          end

          def choices
            { @game.forced_national_choice => "Convert #{current_entity.name} to a national" }
          end

          def process_choose(action)
            entity = action.entity
            raise GameError, "#{entity.name} cannot be converted to a national" unless @game.forced_national_conversion?(entity)
            raise GameError, "Invalid choice: #{action.choice}" unless action.choice == @game.forced_national_choice

            @game.force_national!(entity)
            pass!
          end

          def can_entity_buy_train?(entity)
            super && !@game.national?(entity)
          end

          def must_buy_train?(entity)
            return false if @game.national?(entity)

            entity.floated? && @game.trainless?(entity) && (!@game.fulfilled_train_obligation?(entity) || entity.type == :major)
          end

          def pass_if_cannot_buy_train?(entity)
            !must_buy_train?(entity)
          end

          def buyable_trains(entity)
            return [] if @game.national?(entity)

            trains = super.reject(&:rusted)
            trains = trains.reject { |t| @game.pullman?(t) && t.owned_by_corporation? } if cannot_afford_transfer?(entity)
            trains = trains.reject { |t| @game.pullman?(t) } if @game.pullman(entity)
            trains = trains.reject { |t| abandoned_minor_train?(t) }
            trains = trains.reject { |t| t.owned_by_corporation? && @game.national?(t.owner) }
            trains = trains.select { |t| @game.pullman?(t) } if at_train_limit?(entity)

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

          def log_skip(entity)
            super unless @game.national?(entity)
          end

          def cannot_afford_transfer?(entity)
            entity.cash < @game.pullman_transfer_price
          end

          def room?(entity, _shell = nil)
            super || pullman_buyable?(entity)
          end

          def pullman_buyable?(entity)
            !@game.pullman(entity) && @depot.available(entity).any? { |t| @game.pullman?(t) && !abandoned_minor_train?(t) }
          end

          def abandoned_minor_train?(train)
            train.owned_by_corporation? && @game.abandoned_minor?(train.owner)
          end

          def at_train_limit?(entity)
            @game.num_corp_trains(entity) >= @game.train_limit(entity)
          end

          def spend_minmax(entity, train)
            return super if !@game.pullman?(train) || !train.owned_by_corporation?

            [@game.pullman_transfer_price] * 2
          end

          def buyable_train_variants(train, entity)
            variants = super
            return variants unless train.owned_by_corporation?

            variants.select { |variant| variant[:name] == train.name }
          end

          def process_buy_train(action)
            if action.train.owned_by_corporation? && action.variant && action.variant != action.train.name
              raise GameError, 'A train purchased from another railroad must keep its current type'
            end

            train = action.train
            if @game.pullman?(train) && train.owned_by_corporation? && action.price != @game.pullman_transfer_price
              price = @game.format_currency(@game.pullman_transfer_price)
              raise GameError, "A Pullman from another railroad costs exactly #{price}"
            end
            if @game.pullman?(train) && @game.pullman(action.entity)
              raise GameError, "#{action.entity.name} already owns a Pullman"
            end
            raise GameError, "#{train.owner.name} is abandoned and its trains cannot be bought" if abandoned_minor_train?(train)
            if !@game.pullman?(train) && at_train_limit?(action.entity)
              raise GameError, "#{action.entity.name} has no room for another train"
            end

            reserved = train.name == '2+2' && train.from_depot?
            royalty = @game.pullman?(train) && train.from_depot? && !@depot.discarded.include?(train)
            super
            @game.pay_pullman_royalty! if royalty
            @game.fulfill_train_obligation!(action.entity) if reserved
          end
        end
      end
    end
  end
end
