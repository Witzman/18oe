# frozen_string_literal: true

require_relative "../../engine/engine_helper"
require_relative "../../engine/g_18_oe/helpers"
require "oe/legal_actions"

# EXTENSION, red until the patch exists (#563 Task 8/9, notes/rueckport-differenz/spec-triage-C.md):
# rulebook 11.1.9, last paragraph: SB and MSP choose their home position in the metropolis; a position that
# triggers the Right-of-Way green tile is not allowed while another one is. Chris' engine has no such rule.
# Patch: Game#home_position_cities + a home token step check (upstream shape: Engine::Step::HomeToken subclass).
describe "G18OE metropolis home position (extension)" do
  include G18OESpecHelpers

  let(:game) { new_game }

  def corp(id)
    game.corporation_by_id(id)
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
      round.next_entity! until round.current_entity == lnwr # SB operates first (regional); LNWR lays the tile
      step = round_step(round, Engine::Game::G18OE::Step::Track)
      hex = game.hex_by_id('R55')
      old_tile = hex.tile
      hex.lay(game.tiles.find { |t| t.name == 'OE4' && !t.hex })
      step.update_token!(Struct.new(:hex).new(hex), lnwr, hex.tile, old_tile)
      game.graph.clear
      round.clear_cache!

      # §11.1.9: SB's president chooses, not the railroad that laid the tile (TOKEN_PLACEMENT_ON_TILE_LAY_ENTITY
      # = :owner, workshop #523); SB's token is taken off the tile first
      expect(hex.tile.cities.flat_map(&:tokens).compact).to be_empty
      expect(round.active_step).to be_a(Engine::Step::HomeToken)
      expect(round.active_step.current_entity).to eq(sb)
      expect(sb.owner).not_to eq(lnwr.owner)
      expect(game.active_players).to eq([sb.owner]) # the seat the bot and the UI ask
      targets = Oe::LegalActions.new(game, limit: nil).token_targets(round.active_step, sb)
      expect(targets.map { |city| hex.tile.cities.index(city) }.sort).to eq([1, 2])
      expect { choose(round, sb, hex, 0) }.to raise_error(Engine::GameError, /Right-of-Way/)
      expect { choose(round, lnwr, hex, 1) }.to raise_error(Engine::GameError)

      choose(round, sb, hex, 1)

      expect(hex.tile.cities[1].tokened_by?(sb)).to be(true)
      expect(round.active_step).to be_a(Engine::Game::G18OE::Step::Track)
      expect(round.current_entity).to eq(lnwr)
    end

    # Task 4b: the regional paid its home token at the float (Game#float_corporation, RB 3.2 step 4), so the deferred
    # home token chosen after a metropolis tile costs nothing more. A treasury of 0 (#595, seed 1, 3p) left the
    # enumerator with no position and the game in a dead end.
    it 'places the deferred home token of a regional with an empty treasury at no further cost (#595)' do
      hex = metropolis!('C74')
      round = stock_round!(game)
      msp = start_regional!(game, 'MSP', player)
      msp.spend(msp.cash, game.bank)

      expect(offered(round, msp, hex)).not_to be_empty
      choose(round, msp, hex, 0)

      expect(hex.tile.cities[0].tokened_by?(msp)).to be(true)
      expect(msp.cash).to eq(0)
    end

    it 'does not charge the deferred home token a second time (#595)' do
      hex = metropolis!('C74')
      round = stock_round!(game)
      msp = start_regional!(game, 'MSP', player)
      thin_treasury!(msp)

      expect { choose(round, msp, hex, 0) }.not_to(change { msp.cash })
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
