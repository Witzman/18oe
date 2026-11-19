# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #56 part 1: owning a port authority marker (§11.3.5): bought by a major for £125 at any time before the
# Buy Trains step of its OR turn, one per major, eight North Sea and eight Mediterranean markers.
describe 'G18OE buying a port authority marker (§11.3.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let!(:lnwr) { start_major!(game, 'LNWR', game.players.first) }
  let(:round) { at_phase!(game, '3') && operating_round_for!(game, 1) }
  let(:track) { round_step(round, Engine::Game::G18OE::Step::Track) }

  before do
    with_trains!(game, lnwr, '2+2')
    game.fulfill_train_obligation!(lnwr)
    lnwr.set_cash(400, game.bank)
    round.instance_variable_set(:@entity_index, round.entities.index(lnwr))
    round.instance_variable_set(:@current_operator, lnwr)
  end

  def buy!(area, step = track)
    step.process_choose(Engine::Action::Choose.new(lnwr, choice: "port_authority:#{area}"))
  end

  it 'starts with eight markers of each water area' do
    expect(game.port_authority_supply).to eq(north_sea: 8, mediterranean: 8)
  end

  it 'offers both markers to a major with £125 in its OR turn, as a choose of the Track step' do
    expect(track.port_authority_choices(lnwr).keys).to eq(%w[port_authority:north_sea port_authority:mediterranean])
    expect(track.actions(lnwr)).to include('choose')
  end

  it 'takes £125 for the marker and puts it on the charter' do
    expect { buy!(:north_sea) }.to change(lnwr, :cash).by(-125)
    expect(game.port_authority(lnwr)).to eq(:north_sea)
    expect(game.port_authority_supply[:north_sea]).to eq(7)
  end

  it 'allows one marker per major' do
    buy!(:north_sea)
    expect(track.port_authority_choices(lnwr)).to eq({})
    expect { buy!(:mediterranean) }.to raise_error(Engine::GameError, /port authority/)
  end

  it 'offers nothing without £125, to a minor, or when the markers of the area are gone' do
    lnwr.set_cash(124, game.bank)
    expect(track.port_authority_choices(lnwr)).to eq({})
    lnwr.set_cash(400, game.bank)
    game.port_authority_supply[:north_sea] = 0
    expect(track.port_authority_choices(lnwr).keys).to eq(%w[port_authority:mediterranean])
  end

  it 'gives the marker back to its supply when the major becomes a national' do
    buy!(:mediterranean)
    game.form_national!(lnwr)
    expect(game.port_authority(lnwr)).to be_nil
    expect(game.port_authority_supply[:mediterranean]).to eq(8)
  end

  it 'is offered in the Token and Route steps too, before the Buy Trains step' do
    token = round_step(round, Engine::Game::G18OE::Step::Token)
    route = round_step(round, Engine::Game::G18OE::Step::Route)
    expect(token.port_authority_choices(lnwr).keys.size).to eq(2)
    expect(route.port_authority_choices(lnwr).keys.size).to eq(2)
  end
end
