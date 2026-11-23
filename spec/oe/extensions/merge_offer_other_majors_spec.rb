# frozen_string_literal: true

# EXTENSION SPEC (#583, #563 Task 9): rulebook 10.5 "need not be owned by the same player". Chris' engine lets a minor owner
# offer the minor to other presidents only in the Consolidation Round (offer_or_merge / offer_or_abandon in Consolidate).
# Patch engine/patches/0018-merge-offer-other-majors.patch: the offer (choice 'offer_or_merge', MergeOffer step with the cash
# price of patch 0008) in every Stock Round from Train Phase 3. Not covered here: the move enumerator (Oe::LegalActions)
# and the view.

require_relative '../../engine/engine_helper'
require_relative '../../engine/g_18_oe/helpers'

describe 'G18OE merge offers to other players\' majors in a Stock Round (RB 10.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game) }
  let(:step) { round.active_step }
  let(:owner) { round.current_entity }
  let(:rival) { game.players.find { |p| p != owner } }
  let(:minor) { start_minor!(game, 'B', owner, 'SP') }

  before do
    allow(game).to receive(:major_phase?).and_return(true)
    game.phase.next!
    round
  end

  def offer!
    act!(round, Engine::Action::Choose.new(owner, choice: 'offer_or_merge', target: minor))
  end

  def answer!(choice)
    act!(round, Engine::Action::Choose.new(rival, choice: choice))
  end

  context 'with a major of another player only' do
    let!(:rival_major) { start_major!(game, 'LNWR', rival) }

    it 'offers the minor to the other presidents' do
      minor
      expect(step.entity_choices(minor)).to eq('offer_or_merge' => 'Offer')
      expect(step.actions(owner)).to include('choose')
    end

    it 'asks the other president, who merges it in with cash between the players' do
      owner_before = owner.cash
      rival_before = rival.cash
      minor
      offer!
      expect(round.active_step).to be_a(Engine::Game::G18OE::Step::MergeOffer)
      answer!('merge_offer:30')
      expect(game.merged_minors[rival_major]).to include(minor)
      expect(owner.cash).to eq(owner_before + 30)
      expect(rival.cash).to eq(rival_before - 30)
    end

    it 'uses the one merge of that major in this Stock Round' do
      minor
      offer!
      answer!('merge_offer')
      expect(round.merged_majors).to include(rival_major)
      expect(game.merge_offer_majors(start_minor!(game, 'C', owner, 'SP'))).not_to include(rival_major)
    end

    it 'keeps the turn open when nobody offers and the owner has no major of his own' do
      minor
      offer!
      act!(round, Engine::Action::Pass.new(rival))
      expect(game.merged_minors[rival_major]).not_to include(minor)
      expect(round.active_step).to be_a(Engine::Game::G18OE::Step::BuySellParShares)
      expect(round.current_actions).to be_empty
    end

    it 'rejects the offer before Train Phase 3' do
      early = new_game
      early_round = stock_round!(early)
      allow(early).to receive(:major_phase?).and_return(true)
      early_owner = early_round.current_entity
      early_minor = start_minor!(early, 'B', early_owner, 'SP')
      start_major!(early, 'LNWR', early.players.find { |p| p != early_owner })
      expect(early_round.active_step.entity_choices(early_minor)).to be_empty
    end
  end

  it 'offers nothing when no other player presides a major' do
    start_major!(game, 'LNWR', owner)
    minor
    expect(step.entity_choices(minor)).to be_empty
  end

  it 'lets the owner merge into his own major when nobody offers' do
    own = start_major!(game, 'LNWR', owner)
    start_major!(game, 'PLM', rival)
    minor
    expect(step.entity_choices(minor)).to eq('offer_or_merge' => 'Offer')
    offer!
    act!(round, Engine::Action::Pass.new(rival))
    expect(round.merge_minor).to eq(minor)
    expect(game.merge_targets(owner, minor)).to eq([own])
  end

  it 'offers only the minor of the current player' do
    start_major!(game, 'LNWR', rival)
    other_minor = start_minor!(game, 'C', rival, 'SP')
    expect(step.entity_choices(other_minor)).to be_empty
  end
end
