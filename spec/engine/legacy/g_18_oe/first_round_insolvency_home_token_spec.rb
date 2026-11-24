# frozen_string_literal: true

# EXTENSION (#563 Task 8/9): home token top-up by the owning player (#367/#369, engine/patches/0007). Since #600 the
# insolvency itself is Chris' (upstream 49c770035: the president declares it with `choose`, Game#first_round_insolvency?).
# Triage: notes/rueckport-differenz/spec-triage-B.md. Do not delete; Task 9 turns it green.

require_relative '../engine_helper'
require_relative 'helpers'

# #471: what the home token (incl. the #369 top-up) and a low par do to the reserved 2+2 (§11.6.1, §11.6.4, §11.6.5).
# These specs state what the engine does today; rows marked "open question" wait for the owner (see #471).
describe 'G18OE first-round insolvency after the home token (#471)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { enter_round!(game, game.stock_round) }
  let(:minors) { %w[A B C D E F G H J K L M].map { |id| game.corporation_by_id(id) } }
  let(:player) { round.current_entity }

  def par_minor!(treasury:)
    minor = minors.find { |m| !m.floated? && !m.owner }
    give_company!(player, game.company_by_id(minor.id))
    fund!(game, minor, treasury) if treasury.positive?
    price = round.active_step.get_par_prices(player, minor).first
    act!(round, Engine::Action::Par.new(player, corporation: minor, share_price: price))
    minor
  end

  def home!(minor, zone)
    city = game.home_token_locations(minor).find { |h| game.region_for_hex(h) == zone }.tile.cities.first
    city.hex.tile.patronage = nil
    act!(round, Engine::Action::PlaceToken.new(minor, city: city, slot: 0))
  end

  def buy_train_step
    enter_round!(game, game.operating_round(1))
    round_step(game.round, Engine::Game::G18OE::Step::BuyTrain)
  end

  # The home token takes the same total from minor plus president whoever pays it: the top-up of #369 moves no
  # money out of the sum the insolvency test (§11.6.5) looks at.
  it 'drops the combined funds by the token cost whether the treasury or the player pays (UK, £40)' do
    minor = par_minor!(treasury: 10)
    player.set_cash(100, game.bank)
    total = minor.cash + player.cash
    home!(minor, 'UK')

    expect(minor.cash + player.cash).to eq(total - 40)
    expect([minor.cash, player.cash]).to eq([0, 70])
  end

  # Owner decision (#471, 2026-11-19): the top-up stays outside the §11.6.4 guard. The float is mandatory (§9.1), so
  # the engine lets it through even if minor and president then cannot pay the reserved 2+2; the insolvency (§11.6.5)
  # is the regular consequence, and the player may choose a cheaper zone.
  it 'lets the top-up pass although minor plus president then hold less than the £100 of the 2+2' do
    minor = par_minor!(treasury: 10)
    player.set_cash(100, game.bank)
    home!(minor, 'UK')

    expect(minor).to be_floated
    expect(minor.cash + player.cash).to be < 100
    step = buy_train_step
    expect(game.first_round_insolvency?(minor)).to be(true)
  end

  # Point 4: neither can pay the whole token (#367 fallback), they pay what they hold, so nothing is left for the
  # 2+2 and the insolvency follows in the minor's first OR (not at the float).
  it 'ends in first-round insolvency in the first OR when the fallback leaves minor and president with nothing' do
    minor = par_minor!(treasury: 5)
    player.set_cash(3, game.bank)
    home!(minor, 'IT')

    expect([minor.cash, player.cash]).to eq([0, 0])
    expect(minor.owner).to eq(player)

    step = buy_train_step
    face_value = game.insolvency_face_value(minor)
    step.process_choose(Engine::Action::Choose.new(minor, choice: game.first_round_insolvency_choice))

    expect(minor.trains.map(&:name)).to eq(['2+2'])
    expect(minor.owner).to be_nil
    expect(minor.presidents_share.owner).to eq(game.share_pool)
    expect(player.cash).to eq(face_value)
    expect(game.insolvent?(minor)).to be(true)
  end

  # Point 3: no rule keeps a player from a low par; §11.6.4 limits only paid track and tokens. A regional at the
  # lowest par (£60) holds £120 and pays £40 for its UK token, so a president with under £20 is insolvent in the first OR.
  it 'lets a regional with a low par and a poor president go insolvent in its first OR (§11.6.5)' do
    regional = start_regional!(game, 'LNWR', game.players.first, par: 60)
    game.players.first.set_cash(10, game.bank)

    expect(regional.cash).to eq(80)
    step = buy_train_step
    expect(game.first_round_insolvency?(regional)).to be(true)
    step.process_choose(Engine::Action::Choose.new(regional, choice: game.first_round_insolvency_choice))
    expect(game.players.first.cash).to eq(120) # own cash into the RR, then the president's certificate (2 x par) back
  end
end
