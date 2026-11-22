# frozen_string_literal: true

# EXTENSION SPEC (#563 Task 8 triage, spec-first for Task 9, red on purpose): Chris' engine has no Orient Express duty
# (§12.2 "not obligated unless part of the best possible routes"): no orient_express_required, no step hook. The patch is
# sketched in notes/rueckport-differenz/spec-triage-A.md (patch 1). The second half (running the routes on the real map)
# also needs the wrapper (Oe::LegalActions, Task 4c) and the new route API (touch_node -> connection_data).

require_relative '../../engine/engine_helper'
require_relative '../../engine/g_18_oe/helpers'
require 'oe/legal_actions'

# #512, §12.2 (rulebook p. 41/42): "A RR is not obligated to run the Orient Express on the first occasion it is
# able to do so, unless such a route is part of the "best possible routes" for all trains on the RR. (Ties do not
# count as best possible.)" Owner's reading (2026-11-20): the combination of routes with the highest total revenue
# over all trains of the RR; on a tie no duty; only for a major without the Orient Express marker.
describe 'G18OE Orient Express duty (§12.2, #512)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:president) { game.players[0] }
  let(:major) { start_major!(game, 'LNWR', president) }

  def city_at(hex_id)
    game.hex_by_id(hex_id).tile.cities.first
  end

  describe 'which best routes make the Orient Express obligatory' do
    let(:train) { with_trains!(game, major, '2+2').first }

    # A route of `train` over `stops` that earns `revenue` (the route search's candidates, stubbed).
    def candidate(stops, revenue)
      route = Engine::Route.new(game, game.phase, train)
      allow(route).to receive(:visited_stops).and_return(stops)
      allow(route).to receive(:stops).and_return(stops)
      allow(route).to receive(:hexes).and_return(stops.map(&:hex))
      allow(route).to receive(:revenue).and_return(revenue)
      route.routes = [route]
      route
    end

    def oe_route(revenue)
      candidate([city_at('AA82'), city_at('M50')], revenue)
    end

    def plain_route(revenue)
      candidate([city_at('AA82'), city_at('N31')], revenue)
    end

    before { allow(game).to receive(:orient_express_reachable?).with(major).and_return(true) }

    it 'requires the Orient Express when the best routes found include it and nothing else earns as much' do
      oe = oe_route(120)
      plain = plain_route(100)

      required = game.orient_express_required(major, [plain], { train => [oe, plain] })

      expect(required[:routes]).to eq([oe])
    end

    it 'does not require it on a tie (§12.2: ties do not count as best possible)' do
      oe = oe_route(100)
      plain = plain_route(100)

      expect(game.orient_express_required(major, [plain], { train => [oe, plain] })).to be_nil
    end

    it 'does not require it when the best routes run without it' do
      oe = oe_route(100)
      plain = plain_route(120)

      expect(game.orient_express_required(major, [plain], { train => [plain, oe] })).to be_nil
    end

    it 'does not require it of a major that holds the Orient Express marker' do
      game.place_orient_express_marker!(major)

      expect(game.orient_express_required(major, [plain_route(100)], { train => [oe_route(120)] })).to be_nil
    end

    it 'does not require it when the submitted routes already make an Orient Express run' do
      oe = oe_route(120)

      expect(game.orient_express_required(major, [oe], { train => [oe] })).to be_nil
    end

    it 'does not reject submitted routes that earn at least as much as the Orient Express routes found' do
      expect(game.orient_express_required(major, [plain_route(130)], { train => [oe_route(120), plain_route(100)] }))
        .to be_nil
    end

    it 'does not require it of a regional' do
      regional = start_regional!(game, 'KSS', president)

      expect(game.orient_express_required(regional, [], {})).to be_nil
    end

    # §12: "An Orient Express run may not consist entirely of sea crossings."
    context 'with a route only over the sea' do
      before do
        lay_tile!(game, 'X33', '5', rotation: 4)
        lay_tile!(game, 'X35', '3', rotation: 0)
        game.graph.clear
      end

      def sea_candidate(revenue)
        route = Engine::Route.new(game, game.phase, train)
        [city_at('M28'), city_at('AA82')].each { |stop| route.touch_node(stop) }
        allow(route).to receive(:revenue).and_return(revenue)
        route.routes = [route]
        route
      end

      it 'does not count London over the sea to Constantinople as an Orient Express run' do
        sea = sea_candidate(150)
        plain = plain_route(100)

        expect(game.orient_express_run?(sea)).to be(false)
        expect(game.orient_express_required(major, [plain], { train => [sea, plain] })).to be_nil
      end
    end
  end

  describe 'running the routes on the real map (Paris - Constantinople)' do
    let(:paris_city) { @path.first.tile.cities.find { |c| c.tokened_by?(major) } }

    before do
      major
      @path = paris_constantinople_chain!(game, major)
    end

    # Paris - Q38 - Q40: no Orient Express run.
    def short_route(train)
      route = Engine::Route.new(game, game.phase, train)
      [paris_city, city_at('Q38'), city_at('Q40')].each { |stop| route.touch_node(stop) }
      route.routes = [route]
      route
    end

    def offered_run
      Oe::LegalActions.new(game).call.grep(Engine::Action::RunRoutes).first
    end

    context 'with one 4+4 train' do
      let(:train) do
        with_trains!(game, major, '4').first.tap { |t| t.variant = '4+4' }
      end

      before { train }

      it 'rejects routes without the Orient Express when the best routes include it' do
        round = route_round!(game, major)

        expect(round.active_step.actions(major)).to include('run_routes')
        expect { act!(game, Engine::Action::RunRoutes.new(major, routes: [short_route(train)])) }
          .to raise_error(/Orient Express is required/)
      end

      it 'offers and accepts the Orient Express run' do
        round = route_round!(game, major)
        run = offered_run

        expect(run.routes.map { |r| game.orient_express_run?(r) }).to eq([true])
        act!(game, run)
        expect(round.orient_express_revenue).to be_positive
      end

      it 'tells the president in the step help, once the routes have been searched' do
        route_round!(game, major)
        offered_run

        expect(Array(game.round.active_step.help)).to include(Engine::Game::G18OE::Game::ORIENT_EXPRESS_REQUIRED)
      end

      it 'accepts routes without the Orient Express once the major holds the marker' do
        game.place_orient_express_marker!(major)
        route_round!(game, major)

        expect { act!(game, Engine::Action::RunRoutes.new(major, routes: [short_route(train)])) }.not_to raise_error
      end

      it 'does not search again while a game is loaded from its log' do
        route_round!(game, major)
        allow(game).to receive(:loading).and_return(true)
        expect(game).not_to receive(:orient_express_required)

        expect { act!(game, Engine::Action::RunRoutes.new(major, routes: [short_route(train)])) }.not_to raise_error
      end
    end

    # §12.1: two 2+2 trains combined into a 4+4 reach Constantinople; the combined train may run only the
    # Orient Express, and leaving it idle gives up the best routes.
    context 'with two 2+2 trains combined (§12.1)' do
      before { with_trains!(game, major, '2+2', '2+2') }

      def combine!
        route_round!(game, major)
        act!(game, Oe::LegalActions.new(game).call.grep(Engine::Action::DoubleHeadTrains).first)
      end

      it 'rejects running nothing with the combined train' do
        combine!

        expect { act!(game, Engine::Action::RunRoutes.new(major, routes: [])) }
          .to raise_error(/Orient Express is required/)
      end

      it 'offers and accepts the Orient Express run of the combined train' do
        combine!
        run = offered_run

        expect(run.routes.map { |r| game.combined_train?(r.train) && game.orient_express_run?(r) }).to eq([true])
        expect { act!(game, run) }.not_to raise_error
      end

      it 'still requires the Orient Express run of a combined train once the combination was made' do
        combine!

        expect(game.double_head_candidates(major)).to eq([])
        expect(game.orient_express_required(major, [])).to include(:revenue)
      end
    end

    # §12.2 (owner, 2026-11-20): "best possible routes" include the combination of the non-permanent trains
    # that §12.1 allows, not only the trains as they stand. Two 2+2 trains reach Constantinople only combined
    # (4+4); their routes without it earn 100, the combined train's Orient Express run more.
    context 'with trains that make the best routes only combined (§12.1)' do
      let(:trains) { with_trains!(game, major, '2+2', '2+2') }

      before { trains }

      def plain_routes
        router = Oe::RouteSearch.new(game)
        router.pick(router.train_routes(major).to_a)
      end

      it 'requires the combination when the combined train earns strictly more than the routes without it' do
        route_round!(game, major)
        plain = plain_routes

        required = game.orient_express_required(major, plain)

        expect(required[:combine]).to match_array(trains)
        expect(required[:revenue]).to be > game.routes_revenue(plain)
      end

      it 'rejects the single trains\' routes and names the trains to combine' do
        round = route_round!(game, major)

        expect { act!(game, Engine::Action::RunRoutes.new(major, routes: plain_routes)) }
          .to raise_error(/Orient Express is required.* Combining 2\+2, 2\+2/)
        expect(round.active_step.actions(major)).to include('double_head_trains')
      end

      it 'offers the combination and no run before it, then the combined train\'s Orient Express run' do
        route_round!(game, major)
        actions = Oe::LegalActions.new(game).call

        expect(actions.grep(Engine::Action::RunRoutes)).to be_empty
        expect(actions.grep(Engine::Action::DoubleHeadTrains).map(&:trains)).to all(match_array(trains))

        act!(game, actions.grep(Engine::Action::DoubleHeadTrains).first)
        run = offered_run
        expect(run.routes.map { |r| game.orient_express_run?(r) }).to eq([true])
        expect { act!(game, run) }.not_to raise_error
      end

      it 'tells the president in the step help' do
        route_round!(game, major)
        Oe::LegalActions.new(game).call

        expect(Array(game.round.active_step.help)).to include(Engine::Game::G18OE::Game::ORIENT_EXPRESS_REQUIRED)
      end

      it 'does not require it when the combined train earns less than the routes without it' do
        route_round!(game, major)
        allow_any_instance_of(Engine::Route).to receive(:revenue) { |r| game.orient_express_run?(r) ? 90 : 50 }

        expect(game.orient_express_required(major, plain_routes)).to be_nil
      end

      it 'does not require it on a tie (§12.2)' do
        route_round!(game, major)
        allow_any_instance_of(Engine::Route).to receive(:revenue) { |r| game.orient_express_run?(r) ? 100 : 50 }

        expect(game.orient_express_required(major, plain_routes)).to be_nil
      end

      it 'does not require it of a major that holds the marker' do
        game.place_orient_express_marker!(major)
        route_round!(game, major)

        expect(game.orient_express_required(major, plain_routes)).to be_nil
      end
    end
  end
end
