# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #224: S2 target list items that no other spec states as a whole scenario: a train bought from another
# railroad in the Major RR Phase (§8.3, §11.6.4) and the discard forced by a lower train limit (§5.2).
describe 'G18OE S2 train scenarios (§8.3, §11.6.4, §5.2)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let(:seller) { start_major!(game, 'LNWR', player) }
  let(:buyer) { start_major!(game, 'GWR', player) }

  before do
    at_phase!(game, '3')
    game.instance_variable_set(:@first_or_complete, true)
  end

  describe 'buying a train from another railroad' do
    before { allow(game).to receive(:major_phase?).and_return(true) }

    let(:train) { with_trains!(game, seller, '3').first }
    let(:round) do
      seller
      buyer
      game.fulfill_train_obligation!(seller)
      game.fulfill_train_obligation!(buyer)
      fund!(game, buyer, 500 - buyer.cash)
      train
      operating_round_for!(game, 1)
    end
    let(:step) { round_step(round, Engine::Game::G18OE::Step::BuyTrain) }

    it 'moves the train and the negotiated price from the buyer to the seller' do
      round
      buyer_cash = buyer.cash
      seller_cash = seller.cash

      step.process_buy_train(Engine::Action::BuyTrain.new(buyer, train: train, price: 120))

      expect(train.owner).to eq(buyer)
      expect(seller.trains).not_to include(train)
      expect([buyer.cash, seller.cash]).to eq([buyer_cash - 120, seller_cash + 120])
    end

    it 'is offered to the buyer among its buyable trains' do
      round
      allow(step).to receive(:current_entity).and_return(buyer)

      expect(step.buyable_trains(buyer)).to include(train)
    end
  end

  describe 'a lower train limit' do
    it 'makes a major with more trains than the new limit discard one, and the step ends' do
      major = start_major!(game, 'LNWR', player)
      trains = with_trains!(game, major, '3', '3', '3', '3')
      game.fulfill_train_obligation!(major)
      round = operating_round_for!(game, 1)
      at_phase!(game, '4')
      # Chris' engine offers the national formation before the discard (form_national_spec); decline it.
      game.national_formation_done!(game.national_formation_player) while game.national_formation_player

      expect(game.crowded_corps).to include(major)
      step = round_step(round, Engine::Step::DiscardTrain)
      expect(step).to be_active
      act!(round, Engine::Action::DiscardTrain.new(major, train: trains.first))

      expect(major.trains).not_to include(trains.first)
      game.instance_variable_set(:@crowded_corps, nil)
      expect(game.crowded_corps).to be_empty
    end
  end
end
