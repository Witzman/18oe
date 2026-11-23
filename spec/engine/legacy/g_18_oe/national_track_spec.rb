# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# §11.1.5, §11.1.6 (#64, BUG-011): "Nationals are exempt from all tile placement expenses; they may
# always lay track at no cost."
describe 'G18OE national track costs (§11.1.5, §11.1.6)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:player) { game.players.first }

  def cost(hex_id, corporation)
    hex = game.hex_by_id(hex_id)
    game.upgrade_cost(hex.tile, hex, corporation, corporation)
  end

  it 'charges a major the terrain cost, the national it forms nothing' do
    lnwr = start_major!(game, 'LNWR', player)
    expect(cost('M30', lnwr)).to eq(45)

    game.form_national!(lnwr)
    expect(cost('M30', lnwr)).to eq(0)
  end

  it 'gives a national in a discount zone no discount to pay either (no log line)' do
    chn = start_major!(game, 'CHN', player)
    game.form_national!(chn)
    log_size = game.log.size

    expect(cost('X23', chn)).to eq(0)
    expect(game.log.size).to eq(log_size)
  end
end
