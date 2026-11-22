# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #467: the §10.5 merge into another player's major may include personal cash between the two players
# (never RR treasury). The rulebook names no direction, so the price is part of the president's offer:
# choice 'merge_offer:<n>', n > 0 the president pays the minor's owner, n < 0 the owner pays the president.
describe 'G18OE cash settlement of a merger into another player\'s major (§10.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game) }
  let(:owner) { round.current_entity }
  let(:rival) { game.players.find { |p| p != owner } }
  let(:minor) { start_minor!(game, 'B', owner, 'SP') }
  let!(:rival_major) { start_major!(game, 'LNWR', rival) }

  before do
    allow(game).to receive(:major_phase?).and_return(true)
    game.phase.next!
    minor
    act!(round, Engine::Action::Choose.new(owner, choice: 'offer_or_merge', target: minor))
  end

  def offer!(choice)
    act!(round, Engine::Action::Choose.new(rival, choice: choice))
  end

  it 'moves cash from the president to the owner for a positive price' do
    owner_before = owner.cash
    rival_before = rival.cash
    offer!('merge_offer:30')
    expect(owner.cash).to eq(owner_before + 30)
    expect(rival.cash).to eq(rival_before - 30)
    expect(game.merged_minors[rival_major]).to include(minor)
  end

  it 'asks the owner to accept when the offer demands payment from the owner' do
    owner_before = owner.cash
    rival_before = rival.cash
    offer!('merge_offer:-30')
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::MergeOffer)
    expect(round.active_step.active_entities).to eq([owner])
    expect(round.active_step.choices[rival_major.id]).to include('30')
    act!(round, Engine::Action::Choose.new(owner, choice: rival_major.id))
    expect(owner.cash).to eq(owner_before - 30)
    expect(rival.cash).to eq(rival_before + 30)
    expect(game.merged_minors[rival_major]).to include(minor)
  end

  it 'takes the cash from the personal purse, not from the RR treasury' do
    treasury = rival_major.cash
    minor_cash = minor.cash
    offer!('merge_offer:30')
    expect(rival_major.cash).to eq(treasury + minor_cash)
  end

  it 'rejects a price the president cannot pay' do
    expect { offer!("merge_offer:#{rival.cash + 1}") }.to raise_error(Engine::GameError, /cash/)
  end

  it 'rejects a price the owner cannot pay' do
    expect { offer!("merge_offer:-#{owner.cash + 1}") }.to raise_error(Engine::GameError, /cash/)
  end

  it 'rejects a malformed price' do
    expect { offer!('merge_offer:abc') }.to raise_error(Engine::GameError, /Cannot make that offer/)
  end

  it 'lets the owner decline when every offer demands payment' do
    owner_before = owner.cash
    offer!('merge_offer:-30')
    act!(round, Engine::Action::Pass.new(owner))
    expect(owner.cash).to eq(owner_before)
    expect(game.merged_minors[rival_major]).not_to include(minor)
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::BuySellParShares)
  end

  it 'rejects a payment of the owner the owner can no longer cover' do
    offer!('merge_offer:-30')
    owner.spend(owner.cash - 10, game.bank)
    expect { act!(round, Engine::Action::Choose.new(owner, choice: rival_major.id)) }
      .to raise_error(Engine::GameError, /cash/)
  end
end
