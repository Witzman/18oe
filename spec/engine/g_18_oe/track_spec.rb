# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE lay track (§11.1)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }

  def operating!
    enter_round!(game, game.operating_round(1))
  end

  def cost(hex_id, corp_id)
    hex = game.hex_by_id(hex_id)
    corporation = game.corporation_by_id(corp_id)
    game.upgrade_cost(hex.tile, hex, corporation, corporation)
  end

  def minor_in(minor_id, zone)
    game.minor_floated_regions[minor_id] = zone
    minor_id
  end

  def wien_with_home!(round)
    lay_first_legal!(game, round, 'R55')
    act!(round, Engine::Action::PlaceToken.new(game.corporation_by_id('SB'), city: game.hex_by_id('R55').tile.cities[1], slot: 0))
  end

  it 'budgets tile points by railroad type (§11.1)' do
    entity = Struct.new(:type, :abilities)
    budgets = %i[minor regional major national].to_h { |type| [type, game.tile_point_budget(entity.new(type, []))] }

    expect(budgets).to eq(minor: 3, regional: 3, major: 6, national: 9)
  end

  it 'gives a regional 3 tile points' do
    start_regional!(game, 'LNWR', player)
    round = operating!

    expect(round.active_step.description).to eq('3 track points')
  end

  it 'charges 1 point for a yellow tile' do
    start_regional!(game, 'LNWR', player)
    round = operating!
    lay_first_legal!(game, round, 'J29')

    expect(round.active_step.description).to eq('2 track points')
  end

  it 'charges 2 points for a yellow metropolis and lets SB choose its home station (§11.1.9)' do
    sb = start_regional!(game, 'SB', player)
    round = operating!
    lay_first_legal!(game, round, 'R55')

    expect(round.active_step).to be_a(Engine::Step::HomeToken)

    act!(round, Engine::Action::PlaceToken.new(sb, city: game.hex_by_id('R55').tile.cities[1], slot: 0))

    expect(round.active_step.description).to eq('1 track points')
    expect(game.hex_by_id('R55').tile.cities[1].tokened_by?(sb)).to be(true)
  end

  it 'charges 2 points for an upgrade' do
    game.phase.next!
    start_regional!(game, 'LNWR', player)
    round = operating!
    lay_first_legal!(game, round, 'J27')

    expect(round.active_step.description).to eq('1 track points')
  end

  it 'refuses a lay that costs more points than remain' do
    game.phase.next!
    start_regional!(game, 'SB', player)
    round = operating!
    wien_with_home!(round)
    tile = game.tiles.find { |t| t.name == 'OE12' }
    action = Engine::Action::LayTile.new(game.corporation_by_id('SB'), tile: tile, hex: game.hex_by_id('R55'), rotation: 0)

    expect { round.process_action(action) }.to raise_error(Engine::GameError, /Cannot lay an upgrade now/)
  end

  it 'gives a major 6 tile points' do
    start_major!(game, 'LNWR', player)
    round = operating!

    expect(round.active_step.description).to eq('6 track points')
  end

  it 'keeps a regional inside its track rights zone (§11.1.4)' do
    lnwr = start_regional!(game, 'LNWR', player)
    round = operating!

    expect(round.active_step.tracker_available_hex(lnwr, game.hex_by_id('Q30'))).to be_nil
    expect(game.hex_within_national_region?(lnwr, game.hex_by_id('J29'))).to be(true)
  end

  it 'lets both zones build in a border hex (PB 4.7)' do
    nancy = game.hex_by_id('Q38')

    expect(game.hex_within_national_region?(game.corporation_by_id('KBS'), nancy)).to be(true)
    expect(game.hex_within_national_region?(game.corporation_by_id('PLM'), nancy)).to be(true)
  end

  it 'does not restrict majors to a zone (§11.1.4)' do
    major = start_major!(game, 'LNWR', player)

    expect(game.hex_within_national_region?(major, game.hex_by_id('Q30'))).to be(true)
  end

  it 'charges full terrain cost outside the discount zones (§11.1.5)' do
    expect(cost('M30', 'LNWR')).to eq(45)
    expect(cost('T23', 'PLM')).to eq(60)
  end

  it 'discounts terrain 20% inside Spain, Italy, Scandinavia and Russia (§11.1.5)' do
    expect([cost('X23', 'CHN'), cost('V9', 'CHN'), cost('Z23', 'CHN'), cost('U44', 'SFAI')]).to eq([96, 36, 24, 96])
  end

  it 'does not discount terrain in another zone' do
    expect(cost('R39', 'CHN')).to eq(30)
  end

  it 'discounts a hex that is only partly inside the zone (§11.1.5)' do
    expect(cost('W22', 'CHN')).to eq(96)
  end

  it 'gives a major the zone discount of a merged minor (§10.5, §11.1.4)' do
    major = start_major!(game, 'LNWR', player)
    minor = game.corporation_by_id(minor_in('B', 'SP'))
    game.merged_minors[major] << minor

    expect(cost('X23', 'LNWR')).to eq(96)
  end

  it 'does not stack a merged minor\'s zone with the same home zone (§11.1.5)' do
    major = start_major!(game, 'CHN', player)
    game.merged_minors[major] << game.corporation_by_id(minor_in('B', 'SP'))

    expect(cost('X23', 'CHN')).to eq(96)
  end

  it 'raises the discount to 50% for F on mountains and hills (§11.1.5, §15.6)' do
    f = minor_in('F', 'SP')

    expect([cost('X23', f), cost('V9', f), cost('Z23', f)]).to eq([60, 22, 24])
  end

  it 'raises the discount to 50% for E on water, rivers and lakes (§11.1.5, §15.5)' do
    e = minor_in('E', 'SP')

    expect([cost('Z23', e), cost('X23', e)]).to eq([15, 96])
    expect(cost('E52', minor_in('E', 'SC'))).to eq(22)
  end

  describe 'Minor E and F (§15.5, §15.6)' do
    def merged_major(id, minor_id, zone = nil)
      major = start_major!(game, id, player)
      minor = game.corporation_by_id(minor_id)
      game.minor_floated_regions[minor_id] = zone if zone
      game.add_minor_charter!(minor, major)
      [major, minor]
    end

    it 'gives E 33% off blue terrain outside any discount zone, rounded down (§15.5)' do
      expect(cost('K64', 'E')).to eq(20)
      expect(cost('M30', 'E')).to eq(30)
      expect(cost('R39', 'E')).to eq(30)
    end

    it 'gives F 33% off green terrain outside any discount zone, rounded down (§15.6)' do
      expect(cost('R39', 'F')).to eq(20)
      expect(cost('M30', 'F')).to eq(45)
      expect(cost('K64', 'F')).to eq(30)
    end

    it 'keeps the 50% in a discount zone for an unmerged minor (§11.1.5)' do
      expect(cost('Z23', minor_in('E', 'SP'))).to eq(15)
    end

    it 'keeps the ability when the minor merges into a major (§10.5)' do
      major, minor = merged_major('LNWR', 'E')

      expect(cost('K64', major.id)).to eq(20)
      expect(cost('R39', major.id)).to eq(30)
      expect(cost('K64', minor.id)).to eq(30)
    end

    it 'keeps F on merging as well' do
      major, = merged_major('LNWR', 'F')

      expect(cost('R39', major.id)).to eq(20)
    end

    it 'gives a major 50% in the merged minor\'s zone and 33% elsewhere' do
      major, = merged_major('LNWR', 'E', 'SP')

      expect([cost('Z23', major.id), cost('K64', major.id)]).to eq([15, 20])
    end

    it 'gives a major without E or F no 33% discount' do
      major = start_major!(game, 'LNWR', player)

      expect(cost('K64', major.id)).to eq(30)
    end

    describe 'extra tile point' do
      let(:major) { merged_major('LNWR', 'E').first }
      let(:round) { enter_round!(game, game.operating_round(1)) }
      let(:step) { round.active_step }

      before do
        major
        round
      end

      it 'is spent only on a yellow tile in a matching hex' do
        expect(step.ef_bonus_id(major, game.hex_by_id('K64'))).to eq('E')
        expect(step.ef_bonus_id(major, game.hex_by_id('R39'))).to be_nil
        expect(step.ef_bonus_id(major, game.hex_by_id('K64'), game.hex_by_id('K64').tile)).to be_nil
      end

      it 'is not given to a major without the ability' do
        other = start_major!(game, 'CHN', player)

        expect(step.ef_bonus_id(other, game.hex_by_id('K64'))).to be_nil
      end

      it 'is not available for an upgrade of a laid hex' do
        hex = game.hex_by_id('K64')
        allow(hex.tile).to receive(:color).and_return(:yellow)

        expect(step.ef_bonus_id(major, hex)).to be_nil
      end

      it 'keeps the step open after the regular points are used, once per OR' do
        step.instance_variable_set(:@points_used, 6)
        allow(step).to receive(:hex_neighbors).and_return([0])
        allow(game).to receive(:hex_within_national_region?).and_return(true)
        expect(step.can_lay_tile?(major)).to be(true)

        step.instance_variable_set(:@ef_bonus_used, ['E'])
        expect(step.can_lay_tile?(major)).to be(false)
        expect(step.ef_bonus_id(major, game.hex_by_id('K64'))).to be_nil
      end

      it 'prices a matching hex one point less for the panel, once per OR (#426)' do
        expect(step.points_for_lay(major, game.hex_by_id('K64'))).to eq(0)
        expect(step.points_for_lay(major, game.hex_by_id('R39'))).to eq(1)

        step.instance_variable_set(:@ef_bonus_used, ['E'])
        expect(step.points_for_lay(major, game.hex_by_id('K64'))).to eq(1)
      end

      it 'makes a matching yellow lay cost one point less' do
        step.instance_variable_set(:@points_used, 5)
        allow(step).to receive(:hex_neighbors).and_return([0])
        allow(game).to receive(:hex_within_national_region?).and_return(true)

        expect(step.tracker_available_hex(major, game.hex_by_id('K64'))).to eq([0])
        step.instance_variable_set(:@points_used, 6)
        expect(step.tracker_available_hex(major, game.hex_by_id('K64'))).to eq([0])
        expect(step.tracker_available_hex(major, game.hex_by_id('R39'))).to be_nil
      end
    end
  end
end
