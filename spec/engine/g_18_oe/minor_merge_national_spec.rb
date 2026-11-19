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
    expect(game.merged_minors[national]).to include(minor)
  end
end
