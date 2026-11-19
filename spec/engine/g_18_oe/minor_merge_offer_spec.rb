# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #65: in an ordinary Stock Round a minor may merge into another player's major when that player
# agrees (§10.5: "agreed on by both owning players"; §10.7). The owner asks the other presidents
# (Step::MergeOffer, as in the Consolidation Round, §10.6): each offers or declines; a single offer
# must be taken, from several the owner chooses. Cash is settled in minor_merge_cash_spec (#467).
describe 'G18OE merging a minor into another player\'s major in a Stock Round (§10.5)' do
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
  end

  def offer!
    act!(round, Engine::Action::Choose.new(owner, choice: 'offer_or_merge', target: minor))
  end

  it 'offers the owner of a minor to ask the other presidents' do
    expect(round.active_step.entity_choices(minor)).to eq('offer_or_merge' => 'Offer')
  end

  it 'shows no offer when no other major has a treasury share' do
    rival_major.treasury_shares.count { |s| !s.president }.times { take_treasury_shares!(game, rival, rival_major, 1) }
    expect(round.active_step.entity_choices(minor)).to eq({})
  end

  it 'asks the rival president, who offers, and merges the minor into the rival major' do
    offer!
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::MergeOffer)
    expect(round.active_step.active_entities).to eq([rival])
    expect { act!(round, Engine::Action::Choose.new(rival, choice: 'merge_offer')) }
      .to change { owner.num_shares_of(rival_major) }.by(1)
    expect(game.merged_minors[rival_major]).to include(minor)
  end

  it 'gives the turn back unchanged when the rival declines and nobody can take the minor' do
    offer!
    act!(round, Engine::Action::Pass.new(rival))
    expect(round.merge_minor).to be_nil
    expect(round.active_step).to be_a(Engine::Game::G18OE::Step::BuySellParShares)
    expect(round.current_entity).to eq(owner)
  end

  it 'lets the owner merge into an own major when the rival declines' do
    own = start_major!(game, 'PLM', owner)
    offer!
    act!(round, Engine::Action::Pass.new(rival))
    expect(round.merge_minor).to eq(minor)
    act!(round, Engine::Action::Merge.new(minor, corporation: own))
    expect(game.merged_minors[own]).to include(minor)
  end

  it 'rejects an offer on a minor of another player' do
    other = start_minor!(game, 'C', rival, 'SP')
    expect { act!(round, Engine::Action::Choose.new(owner, choice: 'offer_or_merge', target: other)) }
      .to raise_error(Engine::GameError, /Cannot offer/)
  end

  it 'is no move of the bots in a Stock Round' do
    require 'oe/strategy_player'
    offer = Engine::Action::Choose.new(owner, choice: 'offer_or_merge', target: minor)
    expect(Oe::StrategyPlayer.merge_offer?(game, offer)).to be(true)
  end
end
