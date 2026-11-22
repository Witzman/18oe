# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

describe 'G18OE minor G, two extra tile points (§15.7, §11.1)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }

  def operating!
    enter_round!(game, game.operating_round(1))
  end

  it 'gives minor G 3 + 2 = 5 tile points while another minor keeps 3 (§15.7, §11.1)' do
    g = start_minor!(game, 'G', player, 'SP')
    other = start_minor!(game, 'B', player, 'SP')

    expect([game.tile_point_budget(g), game.tile_point_budget(other)]).to eq([5, 3])
  end

  it 'shows the 5 points to the minor in its lay track step every OR (§15.7)' do
    start_minor!(game, 'G', player, 'SP')

    expect(operating!.active_step.help).to eq('5 track points')
    expect(enter_round!(game, game.operating_round(2)).active_step.help).to eq('5 track points')
  end

  it 'does not give a regional or a major the bonus without the ability (§11.1)' do
    regional = start_regional!(game, 'LNWR', player)
    major = start_major!(game, 'CHN', player)

    expect([game.tile_point_budget(regional), game.tile_point_budget(major)]).to eq([3, 6])
  end

  describe 'when merged (§10.5 "majors only: the minor\'s special ability")' do
    let(:round) { stock_round!(game) }
    let(:holder) { round.current_entity }
    let(:major) { start_major!(game, 'LNWR', holder) }
    let(:minor) { start_minor!(game, 'G', holder, 'SP') }

    before do
      allow(game).to receive(:major_phase?).and_return(true)
      game.phase.next!
      major
      minor
    end

    def merge!
      act!(round, Engine::Action::Choose.new(round.current_entity, choice: minor.id))
      act!(round, Engine::Action::Merge.new(minor, corporation: major))
    end

    it 'moves the +2 to the major, so it gets 6 + 2 = 8 points' do
      expect(game.tile_point_budget(major)).to eq(6)

      merge!

      expect(game.tile_point_budget(major)).to eq(8)
    end

    it 'leaves the closed minor without the ability' do
      merge!

      expect(minor.abilities).to be_empty
    end

    it 'does not change what another major gets' do
      other = start_major!(game, 'CHN', holder)
      merge!

      expect(game.tile_point_budget(other)).to eq(6)
    end
  end
end
