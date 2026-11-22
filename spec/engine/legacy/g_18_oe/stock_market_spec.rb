# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# The grid of the printed Info Board (input/map/stockboard.png in the workshop, #482), nine rows; every row
# starts at the physical column of its leftmost field, so the major par column (red) is column 4 in each row.
describe 'G18OE stock market grid (§4, §4.4)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:market) { game.stock_market }

  BOARD_ROWS = [
    [nil, nil, nil, 110, 120, 135, 150, 165, 180, 200, 225, 250, 280, 310, 350, 390, 440, 490, 550],
    [nil, nil, 90, 100, 110, 120, 135, 150, 165, 180, 200, 225, 250, 280, 310, 350, 390, 440, 490],
    [nil, 75, 80, 90, 100, 110, 120, 135, 150, 165, 180, 200, 225, 250, 280, 310],
    [65, 70, 75, 80, 90, 100, 110, 120, 135, 150, 165, 180, 200],
    [60, 65, 70, 75, 80, 90, 100, 110, 120, 135, 150],
    [55, 60, 65, 70, 75, 80, 90, 100, 110],
    [50, 55, 60, 65, 70, 75, 80],
    [40, 50, 55, 60, 65, 70],
    [30, 40, 50, 55, 60],
  ].freeze

  def at(row, col)
    market.share_price([row, col])
  end

  def price(coordinates)
    market.share_price(coordinates)&.price
  end

  it 'has the nine rows of the printed board, cell by cell' do
    expect(market.market.map { |row| row.map { |sp| sp&.price } }).to eq(BOARD_ROWS)
  end

  it 'puts the six major par values in the red column (column 4) and the six regional par values in column 2' do
    majors = market.market.flatten.compact.select { |sp| sp.type == :convert_range }
    expect(majors.map { |sp| [sp.price, sp.coordinates[1]] }).to eq([[120, 4], [110, 4], [100, 4], [90, 4], [80, 4], [75, 4]])
    regionals = market.par_prices.map { |sp| [sp.price, sp.coordinates[1]] }
    expect(regionals).to eq([[90, 2], [80, 2], [75, 2], [70, 2], [65, 2], [60, 2]])
  end

  it 'moves DOWN one row and does not move where nothing lies below' do
    expect(price(market.down(nil, [3, 4]))).to eq(80)
    expect(market.down(nil, [8, 0])).to eq([8, 0])
    expect(price(market.down(nil, [8, 4]))).to eq(60)
  end

  it 'moves DOWN from the bottom of a column to the field below that the board has (£30 row)' do
    expect(price(market.down(nil, [7, 0]))).to eq(30)
    expect(price(market.down(nil, [7, 3]))).to eq(55)
  end

  it 'moves LEFT one field and DOWN at the left edge (the arrows of the board)' do
    expect(price(market.left(nil, [3, 5]))).to eq(90)
    expect(price(market.left(nil, [0, 3]))).to eq(100) # £110 top row: no field left, down
    expect(price(market.left(nil, [3, 0]))).to eq(60)  # £65: down
    expect(price(market.left(nil, [7, 1]))).to eq(40)
  end

  it 'does not move LEFT from the bottom left field (£30)' do
    expect(market.left(nil, [8, 0])).to eq([8, 0])
  end

  it 'moves RIGHT one field and UP at the right edge' do
    expect(price(market.right(nil, [4, 4]))).to eq(90)
    expect(price(market.right(nil, [5, 8]))).to eq(120) # £110 end of row 6: up to row 5, same column
    expect(price(market.right(nil, [8, 3]))).to eq(60)
    expect(price(market.right(nil, [8, 4]))).to eq(65) # £60 end of the bottom row: up
  end

  it 'moves UP, and RIGHT where no field lies above (top row and the stepped left edge)' do
    expect(price(market.up(nil, [3, 4]))).to eq(100)
    expect(price(market.up(nil, [0, 4]))).to eq(135) # top row: RIGHT
    expect(price(market.up(nil, [1, 2]))).to eq(100) # £90: no field above, RIGHT
    expect(price(market.up(nil, [2, 1]))).to eq(80)  # £75
    expect(price(market.up(nil, [3, 0]))).to eq(70)  # £65
    expect(price(market.up(nil, [4, 0]))).to eq(65) # £60 has £65 above (row 4, same column)
  end

  it 'does not move from £550' do
    expect(market.up(nil, [0, 18])).to eq([0, 18])
    expect(market.right(nil, [0, 18])).to eq([0, 18])
  end

  it 'has the right-edge UP arrows of the board' do
    { [1, 18] => 550, [2, 15] => 350, [3, 12] => 225, [4, 10] => 150, [5, 8] => 110, [6, 6] => 80, [7, 5] => 70 }.each do |from, _|
      row, col = from
      expect(market.right(nil, from)).to eq([row - 1, col])
    end
  end
end
