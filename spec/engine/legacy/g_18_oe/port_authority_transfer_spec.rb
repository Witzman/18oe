# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/strategy_player'

# #469: Transfer of a port authority marker (§11.3.5 with §11.5) in the Transfer Tokens step: a major buys the
# marker of another major of the same player for exactly £125, paid to the selling major. One marker per major.
describe 'G18OE port authority marker transfer (§11.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }
  let!(:lnwr) { start_major!(game, 'LNWR', player) }
  let!(:gwr) { start_major!(game, 'GWR', player) }
  let(:round) { at_phase!(game, '3') && operating_round_for!(game, 1) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::TransferTokens) }
  let(:choice) { 'transfer_marker:GWR' }

  before do
    with_trains!(game, lnwr, '2+2')
    with_trains!(game, gwr, '2+2')
    game.fulfill_train_obligation!(lnwr)
    game.fulfill_train_obligation!(gwr)
    lnwr.set_cash(500, game.bank)
    gwr.set_cash(500, game.bank)
    round.instance_variable_set(:@entity_index, round.entities.index(lnwr))
    round.instance_variable_set(:@current_operator, lnwr)
    game.buy_port_authority!(gwr, 'port_authority:mediterranean')
  end

  def transfer!
    step.process_choose(Engine::Action::Choose.new(lnwr, choice: choice))
  end

  it 'offers the marker of another major of the same player as a choose of the Transfer Tokens step' do
    expect(step.choices.keys).to eq([choice])
    expect(step.choices[choice]).to include('£125')
    expect(step.actions(lnwr)).to include('choose', 'pass')
  end

  it 'moves the marker for exactly £125 to the selling major, keeping its water area' do
    expect { transfer! }.to change(lnwr, :cash).by(-125).and change(gwr, :cash).by(125)
    expect(game.port_authority(lnwr)).to eq(:mediterranean)
    expect(game.port_authority(gwr)).to be_nil
    expect(game.port_authority_supply).to eq(north_sea: 8, mediterranean: 7)
  end

  it 'offers nothing when the buyer owns a marker itself, or has less than £125' do
    lnwr.set_cash(124, game.bank)
    expect(step.choices).to eq({})
    lnwr.set_cash(500, game.bank)
    game.buy_port_authority!(lnwr, 'port_authority:north_sea')
    expect(step.choices).to eq({})
    expect { transfer! }.to raise_error(Engine::GameError, /marker/)
  end

  it 'offers nothing for a major of another player or a major without a marker' do
    other = start_major!(game, 'PLM', game.players.last)
    other.set_cash(500, game.bank)
    game.buy_port_authority!(other, 'port_authority:north_sea')
    expect(step.choices.keys).to eq([choice])
    game.port_authority_off!(gwr)
    expect(step.choices).to eq({})
  end

  it 'is not offered to a minor' do
    expect(game.port_authority_transfer_choices(game.corporation_by_id('A'))).to eq({}) if game.corporation_by_id('A')
  end

  it 'lets the Bot skip it like the token transfers' do
    action = Engine::Action::Choose.new(lnwr, choice: choice)
    expect(Oe::StrategyPlayer.pullman_choice?(action)).to be(true)
  end
end
