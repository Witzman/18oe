# frozen_string_literal: true

require_relative '../engine_helper'
require_relative 'helpers'

# #509 (review #203): private markers of a minor at a minor merge (§10.5) and at abandonment (§9.5):
# the Swift Metropolitan 2+2 (§14.10) and the pass-through tokens of Star Harbor and Central Circle (§14.5, §14.6).
describe 'G18OE privates of a minor that merges or is abandoned' do
  include G18OESpecHelpers

  let(:game) { new_game }
  let(:round) { stock_round!(game) }
  let(:player) { round.current_entity }
  let(:major) { start_major!(game, 'LNWR', player) }
  let(:minor) { start_minor!(game, 'B', player, 'SP') }
  let(:sml) { give_company!(player, game.company_by_id('SML')) }
  let(:shtc) { give_company!(player, game.company_by_id('SHTC')) }

  before do
    allow(game).to receive(:major_phase?).and_return(true)
    game.phase.next!
  end

  def merge!
    act!(round, Engine::Action::Choose.new(round.current_entity, choice: minor.id))
    act!(round, Engine::Action::Merge.new(minor, corporation: major))
  end

  def pass_tokens!
    token_step = Engine::Game::G18OE::Step::MergeToken
    act!(round, Engine::Action::Pass.new(round.current_entity)) while round.active_step.is_a?(token_step)
  end

  # Chris: the SML train is taken from the rusted pool of the Locomotive Works (acquire_swift_metropolitan_train!).
  def give_sml_train!(corporation)
    train = game.depot.upcoming.find { |t| t.name == '2+2' }
    game.depot.reclaim_train(train)
    train.rusted = true
    game.acquire_swift_metropolitan_train!(corporation)
    game.swift_metropolitan_train
  end

  def pass_token_for(corporation)
    game.hexes.flat_map { |hex| hex.tile.cities }.flat_map(&:extra_tokens)
        .select { |token| token.type == :pass_through && token.corporation == corporation }
  end

  def port_city
    game.hexes.flat_map { |hex| hex.tile.cities }
        .find { |city| game.port_hex?(city.hex) && city.tokens.compact.empty? }
  end

  describe 'Swift Metropolitan Line (§14.10)' do
    it 'does not offer the preserved 2+2 of the merging minor to be declined' do
      major
      sml_train = give_sml_train!(minor)
      merge!
      pass_tokens!
      expect(major.trains).to include(sml_train)
      expect(round.active_step).not_to be_a(Engine::Game::G18OE::Step::MergeDiscardTrain)
      expect(sml_train.extra).to be true
    end

    it 'offers only the ordinary trains of the minor to be declined' do
      major
      give_sml_train!(minor)
      ordinary = game.depot.upcoming.first
      game.buy_train(minor, ordinary, :free)
      merge!
      pass_tokens!
      step = round.active_step
      expect(step).to be_a(Engine::Game::G18OE::Step::MergeDiscardTrain)
      expect(step.trains(major)).to eq([ordinary])
    end
  end

  # EXTENSION (#563 Task 9, patch 'pass-through tokens follow a merging minor'): red on Chris' engine. A merge into a
  # major moves the token to the major, a merge into a national and an abandonment remove it (owner decision 2026-11-20, #509).
  describe 'pass-through tokens (§14.5, §14.6)' do
    # Owner decision 2026-11-20: a major takes over all tokens of a merged minor, without a choice.
    it 'passes the token of a minor merged into a major to the major' do
      major
      city = port_city
      game.place_pass_through_token!(shtc, minor, city)
      merge!
      pass_tokens!
      expect(pass_token_for(minor)).to be_empty
      expect(pass_token_for(major).size).to eq(1)
      expect(city.extra_tokens.map(&:corporation)).to eq([major])
    end

    it 'gives the major the effect of the token: no city limit use, no blocking' do
      major
      city = port_city
      game.place_pass_through_token!(shtc, minor, city)
      merge!
      pass_tokens!
      expect(game.pass_through_city?(city, major)).to be true
      expect(game.pass_through_city?(city, minor)).to be false
      expect(game.city_tokened_by?(city, major)).to be false
    end

    it 'passes a Central Circle token too' do
      major
      city = game.hexes.flat_map { |hex| hex.tile.cities }
                 .find { |c| !game.port_hex?(c.hex) && c.tokens.compact.empty? }
      game.place_pass_through_token!(game.company_by_id('CCTC'), minor, city)
      merge!
      pass_tokens!
      expect(city.extra_tokens.map(&:corporation)).to eq([major])
    end

    it 'removes the token of a minor merged into a national (abandoned, §10.5)' do
      national = start_major!(game, 'PLM', player)
      game.form_national!(national)
      game.place_pass_through_token!(shtc, minor, port_city)
      act!(round, Engine::Action::Choose.new(round.current_entity, choice: minor.id))
      act!(round, Engine::Action::Merge.new(minor, corporation: national))
      expect(pass_token_for(minor)).to be_empty
      expect(pass_token_for(national)).to be_empty
    end

    it 'leaves no pass token of an abandoned minor on the map (§9.5 step 3)' do
      game.place_pass_through_token!(shtc, minor, port_city)
      game.abandon_minor!(minor)
      expect(pass_token_for(minor)).to be_empty
    end
  end
end
