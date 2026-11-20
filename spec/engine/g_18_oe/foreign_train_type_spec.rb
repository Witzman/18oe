# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# §11.6: "A train purchased from another RR must remain the same type of train that the original purchaser
# chose." Depot and Open Market trains may be bought as either type; a train of another RR keeps its type.
describe 'G18OE a train bought from another RR keeps its type (§11.6, #518)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let(:buyer) { start_minor!(game, 'K', player, 'RU') }
  let(:seller) { start_regional!(game, game.corporations.find { |c| c.type == :regional }.id, player) }
  let(:round) do
    buyer
    seller
    allow(game).to receive(:major_phase?).and_return(true)
    game.fulfill_train_obligation!(buyer)
    game.fulfill_train_obligation!(seller)
    game.instance_variable_set(:@first_or_complete, true)
    enter_round!(game, game.operating_round(1))
  end
  let(:step) { round_step(round, Engine::Game::G18OE::Step::BuyTrain) }

  def offer(entity, train)
    step.process_buy_train(Engine::Action::BuyTrain.new(entity, train: train, price: 150, variant: yield))
  end

  def own!(corporation, name, variant)
    train = with_trains!(game, corporation, name).first
    train.variant = variant
    train
  end

  before do
    round
    fund!(game, buyer, 500)
    game.instance_variable_set(:@turn, 2)
    allow(step).to receive(:current_entity).and_return(buyer)
  end

  it 'offers no variant choice for the express 3 of another RR' do
    train = own!(seller, '3', '3+3')

    expect(step.buyable_trains(buyer)).to include(train)
    expect(step.buyable_train_variants(train, buyer).map { |v| v[:name] }).to eq(['3+3'])
  end

  it 'offers no variant choice for the local 3 of another RR' do
    train = own!(seller, '3', '3')

    expect(step.buyable_train_variants(train, buyer).map { |v| v[:name] }).to eq(['3'])
  end

  it 'refuses buying the local 3 of another RR as an express 3+3' do
    train = own!(seller, '3', '3')

    expect { offer(buyer, train) { '3+3' } }.to raise_error(Engine::GameError)
    expect(train.owner).to eq(seller)
  end

  it 'refuses buying the express 3+3 of another RR as a local 3' do
    train = own!(seller, '3', '3+3')

    expect { offer(buyer, train) { '3' } }.to raise_error(Engine::GameError)
    expect(train.owner).to eq(seller)
  end

  it 'keeps the type when the express 3+3 is bought without a variant' do
    train = own!(seller, '3', '3+3')
    offer(buyer, train) { nil }

    expect([train.owner, train.name]).to eq([buyer, '3+3'])
  end
end
