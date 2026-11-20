# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'
require 'oe/legal_actions'

describe 'G18OE place token (§11.2)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:step) { Engine::Game::G18OE::Step::Token.new(game, []) }

  def check(corporation, hex_id)
    hex = game.hex_by_id(hex_id)
    step.check_connected(corporation, hex.tile.cities.first, hex)
  end

  def corp(id)
    game.corporation_by_id(id)
  end

  it 'keeps a regional token inside its zone' do
    expect { check(corp('LNWR'), 'Q30') }.to raise_error(Engine::GameError, /outside .* track rights zone/)
    expect(step.available_hex(corp('LNWR'), game.hex_by_id('Q30'))).to be_nil
  end

  it 'lets only French rights token in Nancy (§11.2 example)' do
    expect { check(corp('KSS'), 'Q38') }.to raise_error(Engine::GameError, /outside .* track rights zone/)
    expect { check(corp('PLM'), 'Q38') }.to raise_error(Engine::GameError, /not connected/)
  end

  it 'counts Dresden as Prussian (§2.1)' do
    expect { check(corp('SB'), 'O52') }.to raise_error(Engine::GameError, /outside .* track rights zone/)
  end

  it 'lets a major token outside its home zone' do
    major = start_major!(game, 'LNWR', game.players.first)

    expect { check(major, 'Q30') }.to raise_error(Engine::GameError, /not connected/)
  end

  describe 'unfloated metropolis home (§11.1.9)' do
    let(:player) { game.players.first }
    let(:hex) { game.hex_by_id('R55') }
    let(:lnwr) { corp('LNWR') }

    def lay_metropolis!
      hex.lay(game.tiles.find { |t| t.name == 'OE4' })
    end

    def tokenable_cities
      hex.tile.cities.each_index.select { |i| hex.tile.cities[i].tokenable?(lnwr, free: true) }
    end

    it 'blocks every other railroad from tokening any city until the home railroad floats' do
      lay_metropolis!

      expect(hex.tile.cities.size).to eq(3)
      expect(tokenable_cities).to eq([])
    end

    it 'prompts the president to choose the home station when the railroad floats' do
      lay_metropolis!
      round = stock_round!(game)
      sb = start_regional!(game, 'SB', player)

      expect(round.active_step).to be_a(Engine::Step::HomeToken)
      expect(round.active_step.current_entity).to eq(sb)
      expect(tokenable_cities).to eq([])
    end

    it 'opens the remaining cities once the home station is chosen' do
      lay_metropolis!
      round = stock_round!(game)
      sb = start_regional!(game, 'SB', player)
      act!(round, Engine::Action::PlaceToken.new(sb, city: hex.tile.cities[1], slot: 0))

      expect(hex.tile.cities[1].tokened_by?(sb)).to be(true)
      expect(hex.tile.reservations).to be_empty
      expect(tokenable_cities).to eq([0, 2])
    end

    it 'unblocks the metropolis when the unfloated railroad closes' do
      lay_metropolis!
      game.close_corporation(corp('SB'))

      expect(hex.tile.reservations).to be_empty
      expect(tokenable_cities).to eq([0, 1, 2])
    end

    it 'still gives a railroad floated before the tile the preprinted home token' do
      sb = start_regional!(game, 'SB', player)

      expect(hex.tile.cities.first.tokened_by?(sb)).to be(true)
      expect(hex.tile.reservations).to be_empty
    end
  end

  # Last paragraph of §11.1.9: "The president may not select a home token position that triggers the need to
  # place a green tile ... if a token position is available that would not do so." OE4 laid unrotated: its three
  # cities exit on sides 0, 2 and 4 of the hex. With a full treasury every position reaches a stop with yellow
  # track; a thin treasury (the terrain costs of the first hex on the way decide) leaves one position in Wien
  # (R55, SB: side 0, a mountain hex) and two in C74 (MSP: sides 2 and 4, water) without a connection.
  describe 'metropolis home position (§11.1.9, last paragraph)' do
    let(:player) { game.players.first }

    def metropolis!(hex_id)
      hex = game.hex_by_id(hex_id)
      hex.lay(game.tiles.find { |t| t.name == 'OE4' && !t.hex })
      hex
    end

    def pending_home(round, corporation)
      expect(round.active_step).to be_a(Engine::Step::HomeToken)
      expect(round.active_step.current_entity).to eq(corporation)
      round.active_step
    end

    def thin_treasury!(corporation)
      corporation.spend(corporation.cash - 20, game.bank)
    end

    def choose(round, corporation, hex, index)
      act!(round, Engine::Action::PlaceToken.new(corporation, city: hex.tile.cities[index], slot: 0))
    end

    def offered(round, corporation, hex)
      step = pending_home(round, corporation)
      Oe::LegalActions.new(game, limit: nil).token_targets(step, corporation).map { |city| hex.tile.cities.index(city) }.sort
    end

    it 'refuses the position that needs the green tile while another does not (SB)' do
      hex = metropolis!('R55')
      round = stock_round!(game)
      sb = start_regional!(game, 'SB', player)
      thin_treasury!(sb)
      pending_home(round, sb)

      expect { choose(round, sb, hex, 0) }.to raise_error(Engine::GameError, /Right-of-Way/)
      expect(hex.tile.cities[0].tokened_by?(sb)).to be(false)
    end

    it 'offers the same positions to the enumerator, and accepts one of them (SB)' do
      hex = metropolis!('R55')
      round = stock_round!(game)
      sb = start_regional!(game, 'SB', player)
      thin_treasury!(sb)

      expect(offered(round, sb, hex)).to eq([1, 2])
      choose(round, sb, hex, 2)
      expect(hex.tile.cities[2].tokened_by?(sb)).to be(true)
    end

    it 'applies to MSP in C74 as well' do
      hex = metropolis!('C74')
      round = stock_round!(game)
      msp = start_regional!(game, 'MSP', player)
      thin_treasury!(msp)

      expect(offered(round, msp, hex)).to eq([0])
      expect { choose(round, msp, hex, 1) }.to raise_error(Engine::GameError, /Right-of-Way/)
      choose(round, msp, hex, 0)
      expect(hex.tile.cities[0].tokened_by?(msp)).to be(true)
    end

    it 'binds the floated SB the same way when another railroad lays the metropolis tile' do
      sb = start_regional!(game, 'SB', player)
      thin_treasury!(sb)
      lnwr = start_major!(game, 'LNWR', game.players.last)
      round = operating_round_for!(game)
      step = round_step(round, Engine::Game::G18OE::Step::Track)
      hex = game.hex_by_id('R55')
      old_tile = hex.tile
      hex.lay(game.tiles.find { |t| t.name == 'OE4' && !t.hex })
      step.update_token!(Struct.new(:hex).new(hex), lnwr, hex.tile, old_tile)
      game.graph.clear
      round.clear_cache!

      # who chooses is not asserted here: the engine lets the laying railroad place the token
      # (TOKEN_PLACEMENT_ON_TILE_LAY_ENTITY = :current_operator), §11.1.9 says SB's president (workshop #520)
      chooser = round.active_step.current_entity
      targets = Oe::LegalActions.new(game, limit: nil).token_targets(round.active_step, chooser)
      expect(targets.map { |city| hex.tile.cities.index(city) }.sort).to eq([1, 2])
      expect { choose(round, chooser, hex, 0) }.to raise_error(Engine::GameError, /Right-of-Way/)
    end

    it 'leaves every position open when yellow track reaches a stop from each of them' do
      hex = metropolis!('R55')
      round = stock_round!(game)
      sb = start_regional!(game, 'SB', player)

      expect(offered(round, sb, hex)).to eq([0, 1, 2])
    end

    it 'leaves the choice free when every position needs the green tile' do
      hex = metropolis!('R55')
      sb = corp('SB')
      allow(game).to receive(:right_of_way_home_position_needed?).and_return(true)

      expect(game.home_position_cities(sb, hex)).to eq(hex.tile.cities)
    end

    it 'does not restrict the choice in the two-player game (PB 5.4/5.5)' do
      game2 = new_game(%w[a b])
      hex = game2.hex_by_id('R55')
      hex.lay(game2.tiles.find { |t| t.name == 'OE4' && !t.hex })

      expect(game2.home_position_cities(game2.corporation_by_id('SB'), hex)).to eq(hex.tile.cities)
    end
  end
end
