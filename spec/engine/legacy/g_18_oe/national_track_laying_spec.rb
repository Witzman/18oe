# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #64 part d: a national has no tokens (§11.2.2). ANNAHME A (workshop #64, open owner question, rule 10):
# the virtual tokens of §11.3.10 ("a token in every city in its home track rights zone") also count as
# the token a laid tile must connect to (§11.1). Alternatives not built: B nationals lay no track;
# C nationals lay anywhere in their zone without any connection.
describe 'G18OE nationals lay track from their virtual tokens (§11.1, §11.3.10, ANNAHME A)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:alice) { game.players[0] }
  let(:lnwr) { start_major!(game, 'LNWR', alice).tap { |c| game.form_national!(c) } }
  let(:round) { operating_round_for!(game) }

  def operate!(corporation)
    round.instance_variable_set(:@entity_index, round.entities.index(corporation))
    round.instance_variable_set(:@current_operator, corporation)
    round_step(round, Engine::Game::G18OE::Step::Track)
  end

  def city(hex_id)
    game.hex_by_id(hex_id).tile.cities.first
  end

  it 'counts every city of the home zone as connected, none outside it' do
    expect(game.city_tokened_by?(city('F25'), lnwr)).to be(true) # Glasgow, UK
    expect(game.city_tokened_by?(city('Q30'), lnwr)).to be(false) # Paris, FR
  end

  it 'is no virtual token for a major' do
    major = start_major!(game, 'GWR', alice)
    expect(game.city_tokened_by?(city('F25'), major)).to be(false)
  end

  it 'lets the national lay track next to a city of its zone' do
    step = operate!(lnwr)

    expect(step.actions(lnwr)).to include('lay_tile')
    expect(game.graph_for_entity(lnwr).connected_hexes(lnwr)).to include(game.hex_by_id('F25'))
  end

  it 'lays a tile in its zone for free' do
    operate!(lnwr)
    lay_first_legal!(game, round, 'J29')

    expect(game.hex_by_id('J29').tile.color).to eq(:yellow)
  end
end
