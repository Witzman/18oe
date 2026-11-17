# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #319: G18OE#compute_stops picks the stops best revenue first instead of trying
# every combination (Base#compute_stops). It must give the same revenue.
describe 'G18OE compute_stops (#319)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:corporation) { game.corporation_by_id('LNWR') }
  let(:base_compute_stops) { Engine::Game::Base.instance_method(:compute_stops) }

  # every train variant of the game (distance rows: towns, then city/offboard/town)
  def variants
    game.depot.trains.flat_map { |train| train.variants.values }.uniq { |v| v[:name] }
  end

  def stop(type, revenue, tokened)
    double("#{type} #{revenue}", type: type, tokened_by?: tokened, route_revenue: revenue)
  end

  def route_with(variant, stops)
    train = double(variant[:name], name: variant[:name], distance: variant[:distance], requires_token: true)
    route = double('route', train: train, phase: game.phase, corporation: corporation, paths: [], chains: [])
    allow(game).to receive(:revenue_stops).with(route).and_return(stops)
    allow(game).to receive(:orient_express_bonus_route?).and_return(false)
    route
  end

  def revenue(route, stops)
    stops.sum { |s| s.route_revenue(route.phase, route.train) }
  end

  it 'gives the revenue of the full combination search on random routes' do
    rng = Random.new(319)
    checked = 0
    variants.each do |variant|
      40.times do
        stops = Array.new(rng.rand(1..11)) do
          stop(%w[city town offboard town].sample(random: rng), rng.rand(0..10) * 10, rng.rand < 0.2)
        end
        route = route_with(variant, stops)
        expected = base_compute_stops.bind(game).call(route)
        actual = game.compute_stops(route)
        expect(revenue(route, actual)).to eq(revenue(route, expected)), "#{variant[:name]}: #{stops.map(&:inspect)}"
        expect(actual.empty?).to eq(expected.empty?)
        expect(actual - stops).to be_empty
        checked += 1
      end
    end
    expect(checked).to be >= 200
  end

  it 'keeps a tokened stop even when better untokened ones fill the slots' do
    variant = variants.find { |v| v[:name] == '2+2' } || variants.first
    stops = [stop('city', 10, true), *Array.new(5) { |i| stop('city', 50 + i, false) }]
    actual = game.compute_stops(route_with(variant, stops))
    expect(actual).to include(stops.first)
  end

  it 'returns no stops without a tokened stop' do
    stops = Array.new(4) { |i| stop('city', 20 + i, false) }
    expect(game.compute_stops(route_with(variants.first, stops))).to eq([])
  end
end
