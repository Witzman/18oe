# frozen_string_literal: true

# engine/patches/0024 (#587): SeaConnectivity#reduced_costs picks the next node from a priority queue instead of scanning
# every tentative cost for the lowest one. The scan made each build quadratic in the number of states, and a Track step
# builds one SeaConnectivity per trial tile lay (Graph#clear drops it): 4-12 s per enumeration from phase 3. Same result.

require 'benchmark'
require_relative '../../engine/engine_helper'

describe 'SeaConnectivity#reduced_costs priority queue' do
  let(:klass) { Engine::Game::G18OE::SeaConnectivity }
  let(:game) { double('game', port_authority_reduction: 2) }

  # The method as it was before the patch (the linear scan), the oracle for the result.
  def scan_costs(edges, seas, reduction, starts)
    initial = Array.new(seas.size, reduction)
    best = { initial => starts.to_h { |node| [node, 0] } }
    settled = Hash.new { |hash, allowances| hash[allowances] = {} }
    loop do
      allowances = node = lowest = nil
      best.each do |available, costs|
        costs.each do |key, cost|
          next if settled[available][key] || (lowest && cost >= lowest)

          allowances = available
          node = key
          lowest = cost
        end
      end
      break unless node

      settled[allowances][node] = true
      edges[node].each do |other, weight, sea, ferry|
        sea_index = seas.index(sea)
        available = sea_index ? allowances[sea_index] : 0
        steps = if available.zero?
                  [[weight, 0]]
                elsif ferry
                  (0..[available, weight].min).map { |spent| [weight - spent, spent] }
                else
                  [[weight, 0], [0, 1]]
                end
        steps.each do |step_weight, spent|
          remaining = allowances
          if spent.positive?
            remaining = allowances.dup
            remaining[sea_index] -= spent
          end
          candidate = lowest + step_weight
          costs = (best[remaining] ||= {})
          known = costs[other]
          costs[other] = candidate if !settled[remaining][other] && (known.nil? || candidate < known)
        end
      end
    end
    best.values.each_with_object({}) do |costs, result|
      costs.each { |key, cost| result[key] = cost if !result.key?(key) || cost < result[key] }
    end
  end

  def connectivity(edges, seas)
    sc = klass.allocate
    sc.instance_variable_set(:@game, game)
    sc.instance_variable_set(:@edges, edges)
    sc.instance_variable_set(:@reduced_seas, seas)
    sc
  end

  def random_edges(rng, size, seas)
    edges = Hash.new { |hash, key| hash[key] = [] }
    (size * 3).times do
      a = rng.rand(size)
      b = rng.rand(size)
      sea = [nil, *seas].sample(random: rng)
      weight = rng.rand(0..4)
      ferry = rng.rand(3).zero? ? true : nil
      edges[a] << [b, weight, sea, ferry]
      edges[b] << [a, weight, sea, ferry]
    end
    edges
  end

  it 'returns the costs of the linear scan on random graphs with port authority reductions' do
    5.times do |seed|
      rng = Random.new(seed)
      seas = %i[north south][0, 1 + (seed % 2)]
      edges = random_edges(rng, 40, seas)
      starts = [0, 7]

      expected = scan_costs(edges, seas, 2, starts)
      actual = connectivity(edges, seas).send(:reduced_costs, starts)

      expect(actual).to eq(expected), "seed #{seed}"
      expect(expected.size).to be > 5
    end
  end

  it 'does not scan every state per step: a 1500-node chain is built well under a second' do
    edges = Hash.new { |hash, key| hash[key] = [] }
    1499.times do |i|
      edges[i] << [i + 1, 1, :north, nil]
      edges[i + 1] << [i, 1, :north, nil]
    end

    costs = nil
    seconds = Benchmark.realtime { costs = connectivity(edges, [:north]).send(:reduced_costs, [0]) }

    expect(costs[1499]).to eq(1497)
    expect(seconds).to be < 1.0
  end
end
