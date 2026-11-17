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
            return national_actions(entity) if national?(entity)
            return [] if first_round_insolvency?(current_entity)

            # §11.6.4: the president may not sell shares to pay for the train.
            actions = super
            @game.class::EBUY_CAN_SELL_SHARES ? actions : actions - ['sell_shares']
          end

          def help
            entity = current_entity
            return super unless entity&.corporation? && entity.type == :major && must_buy_train?(entity)

            'A major without a train must buy the cheapest one from the Locomotive Works or the Open Market ' \
              "(§11.6.4). Its president pays the difference from his own cash and may not sell shares. " \
              'A train of another railroad may be bought for the treasury only. If treasury and president ' \
              'cannot pay, the major converts into a national.'
          end

          # §11.6.4: a train of another railroad is paid from the buyer's treasury only; the president's
          # cash goes only to the cheapest train of the Locomotive Works or the Open Market.
          def spend_minmax(entity, train)
            return [1, buying_power(entity)] if train.owned_by_corporation?

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
            return false if entity.type == :national

            entity.floated? && entity.trains.empty? && (!@game.fulfilled_train_obligation?(entity) || entity.type == :major)
          end

          def buyable_trains(entity)
            return national_train_offers(entity).map(&:first).uniq if national?(entity)

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
            return process_national_train(action) if national?(action.entity)

            check_depot_price!(action)
            reserved = action.train.name == '2+2' && action.train.from_depot?
            super
            @game.fulfill_train_obligation!(action.entity) if reserved
          end

          # §11.6, §15.9: the price of a side of a Locomotive Works or Open Market card for `entity`:
          # its face value, less the discount of Minor J's charter (upstream's :train_discount, held by
          # J or the major it merged into). A train of another RR has a negotiated price instead.
          def depot_price(entity, train, variant_name = train.name)
            side = train.clone
            side.variant = variant_name
            Array(@game.abilities(entity, :train_discount, time: ability_timing))
              .map { |ability| ability.discounted_price(side, side.price) }.min || side.price
          end

          # The engine takes the price of a depot train from the action (as upstream does); it may not
          # be below the buyer's price. Face value stays accepted (stored logs bought J's trains at it).
          def check_depot_price!(action)
            train = action.train
            return unless train.from_depot?

            variant_name = action.variant || train.name
            price = depot_price(action.entity, train, variant_name)
            return if action.price >= price

            raise GameError, "#{action.entity.name} must pay #{@game.format_currency(price)} for the " \
                             "#{variant_name} train, not #{@game.format_currency(action.price)} (wrong price)"
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

          # ---- §11.6.6 National Trains ------------------------------------------------------------
          # A national buys no train. It takes unclaimed rusted trains for free up to its train limit,
          # exchanges a rusted train for a higher level unclaimed one, and upgrades a rusted train with a
          # train of a major of its owner (the bank pays that major half the face value). Each is a
          # BuyTrain at price 0; `exchange` names the rusted train given back (upstream's exchange field).

          def national?(entity)
            entity&.corporation? && entity.type == :national
          end

          def national_actions(entity)
            return [] unless entity == current_entity

            national_train_offers(entity).empty? ? [] : %w[buy_train pass]
          end

          # [train, exchange] pairs: one unclaimed rusted train per card level, each own rusted train
          # (one per card) against a higher level unclaimed one and against every train of an own major.
          def national_train_offers(entity)
            pool = @game.unclaimed_rusted_trains.uniq(&:sym)
            offers = []
            offers.concat(pool.map { |train| [train, nil] }) if @game.num_corp_trains(entity) < @game.train_limit(entity)
            entity.trains.select(&:rusted).uniq(&:sym).each do |rusted|
              pool.each { |train| offers << [train, rusted] if train_level(train) > train_level(rusted) }
              own_major_trains(entity).each { |train| offers << [train, rusted] }
            end
            offers
          end

          def own_major_trains(entity)
            @game.corporations.select { |c| c.type == :major && !c.closed? && c.owner == entity.owner }
                 .flat_map { |major| major.trains.reject(&:rusted) }
          end

          def train_level(train)
            train.sym.to_i
          end

          def process_national_train(action)
            entity = action.entity
            train = action.train
            exchange = action.exchange
            raise GameError, 'A national pays nothing for its trains (§11.6.6)' unless action.price.zero?
            if exchange && !(exchange.owner == entity && exchange.rusted)
              raise GameError, 'A national gives back only one of its own rusted trains'
            end

            if train.rusted && train.owner.nil?
              national_claim!(entity, train, exchange)
            elsif own_major_trains(entity).include?(train)
              national_upgrade!(entity, train, exchange)
            else
              raise GameError, "#{entity.name} cannot take the #{train.name} train (§11.6.6)"
            end
            pass! if national_train_offers(entity).empty?
          end

          def national_claim!(entity, train, exchange)
            if exchange
              unless train_level(train) > train_level(exchange)
                raise GameError, 'A rusted train is exchanged only for a higher level one (§11.6.6)'
              end
            elsif @game.num_corp_trains(entity) >= @game.train_limit(entity)
              raise GameError, "#{entity.name} is at its train limit"
            end

            give_back!(exchange) if exchange
            @game.buy_train(entity, train, :free)
            @game.flip_to_local!(train)
            @log << "#{entity.name} #{exchange ? "exchanges its rusted #{exchange.name} for" : 'claims'} " \
                    "a rusted #{train.name} train for free"
          end

          def national_upgrade!(entity, train, exchange)
            raise GameError, 'A national upgrades only a rusted train it gives back (§11.6.6)' unless exchange

            major = train.owner
            amount = train.price / 2
            give_back!(exchange)
            @game.buy_train(entity, train, :free)
            @game.bank.spend(amount, major) if amount.positive?
            @log << "#{entity.name} upgrades its rusted #{exchange.name} with the #{train.name} train of " \
                    "#{major.name}; the bank pays #{major.name} #{@game.format_currency(amount)}"
          end

          # The rusted train goes back into the Locomotive Works, unclaimed.
          def give_back!(train)
            @game.remove_train(train)
            train.owner = nil
          end
        end
      end
    end
  end
end
