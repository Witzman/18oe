# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #413: §11.3.9 / §12.1: "A Pullman car attached to a combined train will only enhance one of the component
# train's revenues (example: combining a 2+2 and a 3+3, with a Pullman, gains a bonus of only £30)". On the
# Orient Express run the combined train is the only route train, so the Pullman must sit on it.
describe 'G18OE Pullman on a combined train (§12.1)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let!(:lnwr) { start_major!(game, 'LNWR', game.players.first) }
  let(:round) { at_phase!(game, '4') && operating_round_for!(game, 1) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::Route) }
  let!(:trains) { with_trains!(game, lnwr, '2+2', '3') }

  before do
    game.fulfill_train_obligation!(lnwr)
    game.receive_pullman!(lnwr)
    round.instance_variable_set(:@entity_index, round.entities.index(lnwr))
    round.instance_variable_set(:@current_operator, lnwr)
    allow(game).to receive(:orient_express_reachable?).and_return(true)
  end

  it 'carries the Pullman on the combined train, adding the highest component level (£30), once' do
    step.process_double_head_trains(Engine::Action::DoubleHeadTrains.new(lnwr, trains: trains.dup))
    combined = lnwr.trains.find { |t| game.combined_train?(t) }

    expect(game.pullman_train(lnwr)).to equal(combined)
    route = instance_double(Engine::Route, corporation: lnwr, train: combined)
    expect(game.pullman_revenue(route)).to eq(30)
  end
end
