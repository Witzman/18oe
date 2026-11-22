# frozen_string_literal: true

# EXTENSION (#581, #563 Task 9): rulebook 14.4 Barclay, Bevan, Barclay and Tritton. Chris' engine has the entity only,
# no effect. Patch engine/patches/0016-bbbt.patch. Rewritten from the legacy specs; the legacy enumerator examples
# (Oe::LegalActions) are not carried over: the enumerator is a later step (Task 4/5).

require_relative "../../engine/engine_helper"
require_relative "../../engine/g_18_oe/helpers"

# #513 (§14.4 (1), PDF p. 43; §10.7 p. 26; §6.1 p. 17), owner's decision B: the owner re-sets the par value of one
# owned regional or major that still has its par value marker, during one of their stock actions in any SR or
# during that RR's OR; a regional takes regional par values, a major major par values; the private then leaves
# the game at once (§6.1).
describe 'G18OE Barclay, Bevan, Barclay and Tritton: Re-Par (§14.4 (1))' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:bbbt) { game.company_by_id('BBBT') }

  describe 'in a stock round' do
    let(:round) { stock_round!(game) }
    let(:step) { round.active_step }
    let(:player) { round.current_entity }
    let(:rival) { game.players.find { |p| p != player } }

    def choose!(choice)
      act!(round, Engine::Action::Choose.new(player, choice: choice, target: bbbt))
    end

    before { give_company!(player, bbbt) }

    it 'offers the other regional par values for an owned regional' do
      start_regional!(game, 'LNWR', player)

      expect(step.entity_choices(bbbt).keys.grep(/repar/)).to eq(%w[65 70 75 80 90].map { |v| "bbbt_repar:LNWR:#{v}" })
    end

    it 'offers nothing for a regional of another player' do
      round
      start_regional!(game, 'LNWR', rival)

      expect(step.entity_choices(bbbt).keys.grep(/repar/)).to be_empty
    end

    it 're-sets the regional par value, the conversion then follows the new letter, and the private leaves at once' do
      regional = start_regional!(game, 'LNWR', player)
      choose!('bbbt_repar:LNWR:80')

      expect(regional.par_price.price).to eq(80)
      expect(regional.share_price.price).to eq(80)
      expect(bbbt).to be_closed
      major_par = game.stock_market.find_relative_share_price(regional.original_par_price, regional, %i[right right up])
      expect(major_par.price).to eq(110) # REGIONAL E (£80) -> MAJOR E (£110), §9.3
    end

    it 'offers the other major par values for an owned major while its par value marker lies' do
      start_major!(game, 'LNWR', player)

      expect(step.entity_choices(bbbt).keys.grep(/repar/)).to eq(%w[80 90 100 110 120].map { |v| "bbbt_repar:LNWR:#{v}" })
    end

    it 're-sets the par value of the major (the price of treasury shares) and the private leaves at once' do
      major = start_major!(game, 'LNWR', player)
      choose!('bbbt_repar:LNWR:110')

      expect(major.par_price.price).to eq(110)
      expect(major.share_price.price).to eq(75) # the share value marker stays (Developer's Note: a brief effect)
      expect(game.bbbt_company).to be_closed
    end

    it 'offers nothing for a major once its par value marker was removed at the end of the SR (§10.7)' do
      start_major!(game, 'LNWR', player)
      game.remove_major_par_markers!

      expect(step.entity_choices(bbbt).keys.grep(/repar/)).to be_empty
    end

    it 'refuses a par value of the other type' do
      start_major!(game, 'LNWR', player)

      expect { choose!('bbbt_repar:LNWR:60') }.to raise_error(Engine::GameError)
    end
  end

  describe "during the RR's operating round" do
    let(:owner) { game.players[0] }
    let(:other) { game.players[1] }

    let(:round) { operating_round_for!(game, 1, setup: true) }

    # The owner's choices through Step::SpecialChoose (upstream's choose_ability), as {choice => text}.
    def offered
      step = round.steps.find { |s| s.is_a?(Engine::Game::G18OE::Step::SpecialChoose) }
      step.actions(bbbt).empty? ? [] : step.choices_ability(bbbt).keys
    end

    def choose!(choice)
      act!(round, Engine::Action::ChooseAbility.new(bbbt, choice: choice))
    end

    it 'offers the owner the other regional par values for the operating regional' do
      give_company!(owner, bbbt)
      operating_regional!(game, 'LNWR', owner)
      round

      expect(offered).to eq(%w[65 70 75 80 90].map { |v| "bbbt_repar:#{v}" })
    end

    it 'accepts the offered re-par: the regional takes the new value and the private leaves at once' do
      give_company!(owner, bbbt)
      regional = operating_regional!(game, 'LNWR', owner)
      round
      choose!('bbbt_repar:75')

      expect(regional.par_price.price).to eq(75)
      expect(bbbt).to be_closed
      expect(offered).to be_empty
    end

    it 'refuses a value the regional cannot take' do
      give_company!(owner, bbbt)
      operating_regional!(game, 'LNWR', owner)
      round

      expect { choose!('bbbt_repar:110') }.to raise_error(Engine::GameError)
    end

    it 'offers nothing while a RR of another player operates' do
      give_company!(owner, bbbt)
      operating_regional!(game, 'LNWR', other)
      round

      expect(offered).to be_empty
    end
  end
end
