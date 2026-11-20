# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #511: review of the merge of a minor into a major against §10.5 (rulebook pp. 24-26): station tokens, track
# rights chit, several abilities in one major, no-share reachability of a national.
describe 'G18OE merge of a minor, review against §10.5 (#511)' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game) }
  let(:player) { round.current_entity }
  let(:major) { start_major!(game, 'LNWR', player) }
  let(:minor) { start_minor!(game, 'B', player, 'SP') }

  before do
    allow(game).to receive(:major_phase?).and_return(true)
    game.phase.next!
  end

  def merge!(target = major, merging: minor)
    act!(round, Engine::Action::Choose.new(round.current_entity, choice: merging.id))
    act!(round, Engine::Action::Merge.new(merging, corporation: target))
  end

  def place_minor_token!(hex_id, index = 0, owner: minor)
    city = game.hex_by_id(hex_id).tile.cities[index]
    city.place_token(owner, owner.next_token, free: true, check_tokenable: false)
    city
  end

  def cost(hex_id, entity)
    hex = game.hex_by_id(hex_id)
    game.upgrade_cost(hex.tile, hex, entity, entity)
  end

  describe 'station tokens (§10.5 p. 25, "Majors only")' do
    # Owner's wording (2026-11-20): "all abilities, so tokens too, automatically". The rulebook text differs:
    # the major may decline tokens and may replace them; so the engine asks per token and takes none by itself.
    # These examples record the current behaviour, they do not change it (open question in #511).
    it 'does not move a minor token to the major by itself, the major has to answer (rulebook: may decline or replace)' do
      major
      city = place_minor_token!('Q38')
      merge!
      expect(round.active_step).to be_a(Engine::Game::G18OE::Step::MergeToken)
      expect(city.tokens.compact.map(&:corporation)).to eq([minor])
      expect(major.placed_tokens.map(&:city)).not_to include(city)
    end

    it 'forces the decline of a token in a hex where the major has a token in another city of that hex (p. 25)' do
      major
      wien = game.hex_by_id('R55').tile.cities
      place_minor_token!('R55', 0)
      wien[1].place_token(major, major.next_token, free: true, check_tokenable: false)
      merge!
      expect(round.active_step).not_to be_a(Engine::Game::G18OE::Step::MergeToken)
      expect(wien[0].tokens.compact).to be_empty
      expect(minor).to be_closed
    end

    it 'lets the major decline one token and replace the other for free (p. 25)' do
      major
      first = place_minor_token!('Q38')
      second = place_minor_token!('W64')
      cash = major.cash
      merge!
      act!(round, Engine::Action::Pass.new(major))
      act!(round, Engine::Action::PlaceToken.new(major, city: second, slot: 0))
      expect(first.tokens.compact).to be_empty
      expect(second.tokens.compact.map(&:corporation)).to eq([major])
      expect(major.cash).to eq(cash + 120)
    end

    it 'takes no token of the minor into a national (p. 25, majors only)' do
      national = start_major!(game, 'GWR', player)
      game.form_national!(national)
      city = place_minor_token!('Q38')
      merge!(national)
      expect(city.tokens.compact).to be_empty
      expect(game.abandoned_minor?(minor)).to be(true)
    end
  end

  describe 'track rights chit (§10.5 pp. 25-26, §11.1.4, §11.1.5)' do
    it 'brings the zone discount of the chit to the major through a real merge' do
      major
      expect(cost('X23', major)).to eq(120)
      merge!
      expect(cost('X23', major)).to eq(96)
    end

    it 'does not add up two chits of the same zone ("no cumulative effect")' do
      major
      second = start_minor!(game, 'C', player, 'SP')
      game.add_minor_charter!(minor, major)
      game.add_minor_charter!(second, major)
      expect(game.track_rights_zones(major).count('SP')).to eq(1)
      expect(cost('X23', major)).to eq(96)
    end

    it 'does not add the discounts of two different discount zones on one hex' do
      major
      italy = start_minor!(game, 'C', player, 'IT')
      game.add_minor_charter!(minor, major)
      game.add_minor_charter!(italy, major)
      expect(cost('X23', major)).to eq(96)
    end

    it 'gives a chit without discount no effect at all' do
      major
      fr_minor = start_minor!(game, 'C', player, 'FR')
      before = [cost('X23', major), cost('V9', major), cost('M30', major)]
      game.add_minor_charter!(fr_minor, major)
      expect([cost('X23', major), cost('V9', major), cost('M30', major)]).to eq(before)
    end
  end

  describe 'several abilities in one major (§10.5 p. 24)' do
    it 'keeps every ability of two merged minors without doubling any' do
      major
      e = start_minor!(game, 'E', player, 'FR')
      f = start_minor!(game, 'F', player, 'AH')
      counts = e.abilities.size + f.abilities.size + major.abilities.size
      game.add_minor_charter!(e, major)
      game.add_minor_charter!(f, major)
      expect(major.abilities.size).to eq(counts)
      expect(major.abilities.uniq.size).to eq(counts)
    end

    it 'lets a major merge again in the next stock round (one merge per major and SR, p. 25)' do
      major
      merge!
      expect(game.merge_targets(player, start_minor!(game, 'C', player, 'IT'))).not_to include(major)
      next_round = stock_round!(game)
      expect(next_round.merged_majors).to be_empty
      expect(game.merge_targets(player, game.corporation_by_id('C'))).to include(major)
    end
  end

  describe 'national without a share in any place (§10.5 p. 25)' do
    let!(:national) do
      corporation = start_major!(game, 'LNWR', player)
      game.form_national!(corporation)
      corporation
    end

    before do
      pool = game.share_pool.shares_by_corporation[national].dup
      game.share_pool.transfer_shares(Engine::ShareBundle.new(pool), player) unless pool.empty?
    end

    # The graph of a national covers the cities of its home zone (no tokens, §9.4), so the check of
    # Game#merge_connected? matches the rulebook for a token inside the zone. A token outside the zone that is joined
    # by track to a zone city is not examined here (needs laid track; not checked, see #511).
    it 'is a target when the minor token stands in a city of the national home track rights zone' do
      hex = game.class::NATIONAL_REGION_HEXES['UK'].map { |c| game.hex_by_id(c) }.find { |h| h&.tile&.cities&.any? }
      expect(hex).not_to be_nil
      expect(game.merge_share(national)).to be_nil
      place_minor_token!(hex.id)
      game.clear_graph
      expect(game.merge_targets(player, minor)).to include(national)
    end

    it 'is no target when the minor token is neither in nor connected to a city of that zone' do
      place_minor_token!('AA82', 1)
      game.clear_graph
      expect(game.merge_share(national)).to be_nil
      expect(game.merge_targets(player, minor)).to be_empty
    end
  end
end
