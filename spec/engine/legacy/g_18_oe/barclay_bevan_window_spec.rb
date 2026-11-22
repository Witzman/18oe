# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

# #476 (§14.4 (3)): the owner may protect a share value marker against DOWN "at the moment another player is
# selling a share of stock". The sale waits in Step::ProtectShare (pattern Step::ReserveShare) for the owner's answer.
describe 'G18OE Barclay, Bevan, Barclay and Tritton: window at a foreign sale (§14.4 (3))' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game) }
  let(:seller) { round.current_entity }
  let(:owner) { game.players.find { |p| p != seller } }
  let(:regional) { start_major!(game, 'LNWR', game.players.find { |p| p != seller && p != owner }) }
  let(:bbbt) { give_company!(owner, game.company_by_id('BBBT')) }

  def sell_action
    share = seller.shares_of(regional).first
    Engine::Action::SellShares.new(seller, shares: share, percent: share.percent)
  end

  def sell!
    act!(round, sell_action)
  end

  def window_step
    round.steps.find { |step| step.is_a?(Engine::Game::G18OE::Step::ProtectShare) }
  end

  before do
    regional
    take_treasury_shares!(game, seller, regional, 3)
    bbbt
    @price = regional.share_price.price
  end

  it 'holds the sale and asks the owner of the private' do
    sell!

    expect(round.active_step).to be(window_step)
    expect(round.active_entities).to eq([owner])
    expect(seller.shares_of(regional)).not_to be_empty
    expect(regional.share_price.price).to eq(@price)
  end

  it 'on pass completes the sale and the marker falls' do
    held = seller.shares_of(regional).size
    sell!
    act!(round, Engine::Action::Pass.new(owner))

    expect(seller.shares_of(regional).size).to eq(held - 1)
    expect(regional.share_price.price).to be < @price
    expect(bbbt).not_to be_closed
    expect(round.active_entities).to eq([seller])
  end

  it 'on protect completes the sale, the marker stays and the private is used up' do
    held = seller.shares_of(regional).size
    sell!
    act!(round, Engine::Action::Choose.new(owner, choice: 'protect'))

    expect(seller.shares_of(regional).size).to eq(held - 1)
    expect(regional.share_price.price).to eq(@price)
    expect(game.bbbt_protected?(regional)).to be(true)
    expect(game.bbbt_exercised?).to be(true)
  end

  it 'does not ask again for the protected corporation' do
    sell!
    act!(round, Engine::Action::Choose.new(owner, choice: 'protect'))
    sell!

    expect(round.active_step).not_to be(window_step)
  end

  it 'does not ask for a sale by the owner of the private' do
    take_treasury_shares!(game, owner, regional, 3)
    pass_until!(round, owner)
    share = owner.shares_of(regional).first
    act!(round, Engine::Action::SellShares.new(owner, shares: share, percent: share.percent))

    expect(round.active_step).not_to be(window_step)
  end

  it 'does not ask once the private is used up or closed' do
    game.instance_variable_set(:@bbbt_used, true)
    sell!

    expect(round.active_step).not_to be(window_step)
  end

  it 'does not ask when nobody owns the private' do
    bbbt.owner.companies.delete(bbbt)
    bbbt.owner = nil
    sell!

    expect(round.active_step).not_to be(window_step)
  end

  it 'is enumerated for the owner as choose and pass, and both are accepted' do
    sell!
    actions = Oe::LegalActions.new(game).call

    expect(actions.map(&:entity).uniq).to eq([owner])
    expect(actions.map(&:class)).to contain_exactly(Engine::Action::Choose, Engine::Action::Pass)
    expect { act!(round, actions.find { |a| a.is_a?(Engine::Action::Choose) }) }.not_to raise_error
  end

  it 'accepts the offered pass too' do
    sell!
    pass = Oe::LegalActions.new(game).call.find { |a| a.is_a?(Engine::Action::Pass) }

    expect { act!(round, pass) }.not_to raise_error
  end
end
