# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# Assumption A2 of #342: the Regional/Minor RR Phase ends with the 18th regional that has FLOATED (§5.1.3, §8.2),
# not with the 18th that has been parred.
describe 'G18OE end of the Regional/Minor RR Phase (§5.1.3, §8.2)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game) }
  let(:step) { round_step(round, Engine::Game::G18OE::Step::BuySellParShares) }
  def unparred
    game.corporations.select { |c| c.type == :regional && !c.ipoed }
  end

  def par_only!(count)
    unparred.first(count).each do |regional|
      game.par_corporation(regional, cell(game, 60, :par))
      regional.ipoed = true
      game.minor_regional_order << regional
    end
  end

  it 'keeps all 24 regionals while fewer than 18 have floated or been parred' do
    float_regionals!(game, 17)

    expect(step.close_unfloated_regionals_at_maximum!).to be_nil
    expect(game.corporations.count { |c| c.type == :regional }).to eq(24)
  end

  it 'removes the six remaining regionals when the 18th regional has floated (§8.2)' do
    float_regionals!(game, 18)
    step.close_unfloated_regionals_at_maximum!

    expect(game.corporations.count { |c| c.type == :regional }).to eq(18)
    expect(unparred).to be_empty
  end

  it 'does not end the Regional/Minor RR Phase while a parred regional is still unfloated (§5.1.3)' do
    float_regionals!(game, 15)
    par_only!(3)
    unparred.each { |c| game.close_corporation(c) }
    game.minor_floated_regions = game.corporations.select { |c| c.type == :minor }.to_h { |m| [m.id, 'RU'] }

    expect(game.regionals_in_play).to eq(18)
    expect(game.major_phase?).to be(false)
  end

  it 'starts the Major RR Phase once the last parred regional floats (§5.1.3)' do
    float_regionals!(game, 15)
    par_only!(3)
    unparred.each { |c| game.close_corporation(c) }
    game.minor_floated_regions = game.corporations.select { |c| c.type == :minor }.to_h { |m| [m.id, 'RU'] }
    game.corporations.select { |c| c.type == :regional && !c.floated? }.each do |regional|
      game.share_pool.buy_shares(game.players.first, regional.presidents_share)
      game.place_home_token(regional)
    end

    expect(game.major_phase?).to be(true)
  end

  it 'does not remove the other regionals while 15 have floated and 3 are only parred (§8.2 "when the 18th is floated")' do
    pending 'deviation: regionals_in_play counts parred regionals, so the 18th par removes the six un-parred regionals (workshop #348)'
    float_regionals!(game, 15)
    par_only!(3)
    step.close_unfloated_regionals_at_maximum!

    expect(unparred.size).to eq(6)
  end
end
