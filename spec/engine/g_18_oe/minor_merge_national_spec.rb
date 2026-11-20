# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #65: a minor merges into a national too (§10.5): the national gets the trains only; token,
# ability and the minor's cash are forfeited (cash to the bank); the owner gets one share from the
# Open Market, if there is one (a national never has treasury stock).
describe 'G18OE merging a minor into a national in a Stock Round (§10.5)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game) }
  let(:player) { round.current_entity }
  let!(:national) do
    corporation = start_major!(game, 'LNWR', player)
    game.form_national!(corporation)
    corporation
  end
  let(:minor) { start_minor!(game, 'B', player, 'SP') }

  before do
    allow(game).to receive(:major_phase?).and_return(true)
    game.phase.next!
  end

  def merge!
    act!(round, Engine::Action::Choose.new(player, choice: minor.id))
    act!(round, Engine::Action::Merge.new(minor, corporation: national))
  end

  it 'offers the national as target of its president' do
    expect(game.merge_targets(player, minor)).to include(national)
  end

  it 'offers no national presided by another player' do
    other = game.players.find { |p| p != player }
    national.owner = other
    expect(game.merge_targets(player, minor)).not_to include(national)
  end

  it 'forfeits the minor cash to the bank and gives the owner the Open Market share' do
    minor
    bank_before = game.bank.cash
    national_cash = national.cash
    expect { merge! }.to change { player.num_shares_of(national) }.by(1)
    expect(national.cash).to eq(national_cash)
    expect(game.bank.cash).to eq(bank_before + 120)
  end

  it 'takes no ability and no token of the minor' do
    abilities = minor.abilities.dup
    merge!
    expect(national.abilities).to be_empty
    expect(abilities).not_to be_empty
    expect(game.merged_minors[national]).not_to include(minor)
  end

  # #506: §10.5 (Nationals only): "the minor is abandoned (see 9.5)", so it is no merged minor of the
  # national; the charter stays in the Open Market and a major may buy it for £60 (§11.7).
  describe 'abandoning the merged minor (#506)' do
    it 'leaves the minor as an abandoned minor, not closed' do
      merge!
      expect(minor).not_to be_closed
      expect(minor.owner).to be_nil
      expect(game.abandoned_minor?(minor)).to be true
      expect(game.abandoned_minors).to include(minor)
      expect(game.merged_minors[national]).to be_empty
    end

    it 'keeps the national zones free of the minor zone' do
      merge!
      expect(game.track_rights_zones(national)).not_to include('SP')
    end

    it 'lets a major buy the charter for the abandoned minor price (§11.7)' do
      merge!
      buyer = game.players.find { |p| p != player }
      major = start_major!(game, 'PLM', buyer)
      expect(game.abandoned_minors).to include(minor)
      game.add_minor_charter!(minor, major)
      expect(game.merged_minors[major]).to include(minor)
      expect(game.abandoned_minor_price).to eq(60)
    end

    context 'with Minor C (Golden Bell)' do
      let(:minor) { start_minor!(game, 'C', player, 'RU') }

      it 'gives the national no Golden Bell choice (§10.5: majors only)' do
        merge!
        expect(game.golden_bell_holder).to be_nil
      end
    end

    context 'with Minor M (Pullman)' do
      let(:minor) { start_minor!(game, 'M', player, 'IT') }

      it 'keeps the Pullman with the charter, not in the Open Market (§9.5)' do
        merge!
        game.event_pullmans_available!
        expect(game.pullman_market).to eq(0)
        expect(game.pullman?(national)).to be false
        expect(game.pullman_m_holder).to eq(minor)
        expect(game.pullman?(minor)).to be true
      end
    end
  end
end
