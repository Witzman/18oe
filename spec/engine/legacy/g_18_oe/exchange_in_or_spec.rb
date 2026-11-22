# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# workshop #399: the Minor exchange privates say "Exchange this private during a Stock Round" (entities.rb) and the
# exchange runs in Step::BuySellParShares (par_via_exchange). Engine::Step::Exchange in the operating-round step list
# never offered anything for them and is dropped.
describe 'G18OE exchange of a Minor private is a stock round action (#399)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }

  it 'has no exchange step in the operating round' do
    steps = operating_round_for!(game, 1).steps.map(&:class)
    expect(steps).not_to include(Engine::Step::Exchange)
  end

  it 'offers no share action for an owned Minor private during an operating round' do
    company = give_company!(player, game.company_by_id('C'))
    fund!(game, player)
    operating_regional!(game, 'BEL', player)
    round = operating_round_for!(game, 1)
    expect(round.actions_for(company)).not_to include('buy_shares')
  end
end
