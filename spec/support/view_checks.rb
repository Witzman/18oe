# frozen_string_literal: true

# The checks of the view specs (#119, #123, #124), shared by the seed-game examples (:game_flow, full stage)
# and the scenario examples whose state is built by code (fast stage, #438). Each check compares what the
# view says with the engine method it comes from; they run inside an example (RSpec expectations).
#
# State the checks keep between calls (instance variables of the example group): @enumerated and @compared
# (how many track panels were compared with a full enumeration), @short (a president had to chip in for a
# train) and @game_for_check (the game after a dividend was paid). A scenario group sets the counters to 0.
module OeViewChecks
  # --- prompt texts (#124) -----------------------------------------------------------------------------

  # The errors of the prompt's texts against the game's active step: description, pass label and help from
  # the step, and every offered choice with a label of its own (not its id; #425: also the choice of a
  # non-blocking step such as Hochberg's token during Track). [] when all hold.
  def prompt_text_errors(game, view)
    prompt = view[:prompt]
    step = game.round.active_step
    name = prompt[:step]
    errors = []
    errors << "#{name}: description #{prompt[:description].inspect}" unless prompt[:description].is_a?(String) && !prompt[:description].empty?
    errors << "#{name}: pass_description" unless prompt[:pass_description].is_a?(String) && !prompt[:pass_description].empty?
    errors << "#{name}: help" unless prompt[:help].nil? || prompt[:help].is_a?(String)
    errors << "#{name}: description differs from the step" unless prompt[:description] == step.description
    chooses = prompt[:actions].select { |a| a["type"] == "choose" }
    errors << "#{name}: #{chooses.size} choose actions but #{prompt[:choices].size} choices" unless chooses.size == prompt[:choices].size
    prompt[:choices].each do |c|
      errors << "#{name}: empty label for #{c[:choice]}" if c[:label].to_s.empty?
      errors << "#{name}: label of #{c[:choice]} is only its id" if c[:label] == c[:choice]
      errors << "#{name}: choice_name" if chooses.any? && step.respond_to?(:choice_name) && prompt[:choice_name] != step.choice_name
    end
    errors
  end

  # --- operating context (#123) ------------------------------------------------------------------------

  def check_shape(ctx)
    expect(ctx.keys).to eq(%i[track token dividend train stock])
    JSON.generate(ctx)
  end

  # Who the actions are for: every acting entity of the offered actions, the step's entity the only primary one.
  def check_acting(view, entity)
    acting = view[:prompt][:acting_as]
    expect(acting.map { |a| a[:entity] }).to eq(view[:prompt][:actions].map { |a| a["entity"] }.uniq)
    expect(acting.select { |a| a[:primary] }.map { |a| a[:entity] } - [entity.id]).to eq([])
  end

  def check_track(track, view, step, entity, game)
    expect(track[:points]).to eq(budget: game.tile_point_budget(entity), used: step.points_used, left: step.points_left(entity))
    expect(track[:hexes]).not_to be_nil if view[:prompt][:viewer_to_act]
    (track[:hexes] || []).each do |h|
      hex = game.hex_by_id(h[:hex])
      expect(step.available_hex(entity, hex)).to be_truthy
      # #360: plus the fee for the sea zones to the hex (§11.1.6)
      expect(h[:cost]).to eq(game.upgrade_cost(hex.tile, hex, entity, entity) + game.cross_water_track_fee(entity, hex).to_i)
      expect(h[:cost_parts].sum { |p| p[:amount] }).to eq(h[:cost])
      expect(h[:points]).to be <= track[:points][:left], "#{h[:hex]}: #{h[:points]} points, #{track[:points][:left]} left"
      expect(h[:points]).to eq(step.points_for_lay(entity, hex)) # #426: with the E/F extra point
      # #360: a tile none of whose rotations the cash can pay (the sea zone fee depends on the sides) is left out of the
      # panel, so the panel lists a subset of the engine's upgradeable tiles; the enumeration check below compares the
      # rotations (and so the omitted tiles) with the legal actions (#458)
      engine_tiles = step.upgradeable_tiles(entity, hex).map { |t| t.name.to_s }
      expect(engine_tiles).to include(*h[:tiles].map { |t| t[:name] })
      h[:tiles].each { |t| expect(t[:rotations]).not_to be_empty }
    end
    compare_sampled_track(track, game) if track[:hexes] && track[:hexes].size > 2 && @compared < 10
    return unless track[:hexes] && @enumerated < 15

    @enumerated += 1
    # the track panel lists the lays of the acting corporation (View#lay_options keeps only these); a private's own
    # tile lay (§14.9, e.g. BBE) is another entity's action and not part of the panel (#458)
    legal = Oe::LegalActions.new(game, limit: nil).call.grep(Engine::Action::LayTile).select { |a| a.entity.equal?(entity) }
    from_view = track[:hexes].flat_map { |h| h[:tiles].flat_map { |t| t[:rotations].map { |r| [h[:hex], t[:name], r] } } }
    expect(from_view.sort).to eq(legal.map { |a| [a.hex.id, a.tile.name.to_s, a.rotation] }.sort)
  end

  # #340: the track panel regrouped from the unsampled legal set equals the one
  # from a second enumeration (taken when the prompt is sampled), order included.
  def compare_sampled_track(track, game)
    @compared += 1
    sampled = Oe::View.render(game, viewer: game.active_players.first&.id, log: nil, actions_limit: 1_000_000)
    expect(sampled[:prompt][:context][:track]).to eq(track)
  end

  def check_token(token, step, entity, game)
    tokens = step.available_tokens(entity)
    expect(token[:tokens_left]).to eq(tokens.size)
    (token[:cities] || []).each do |c|
      expect(c[:price]).to be_a(Integer)
      city = game.city_by_id(c[:id])
      expect(city.hex.id).to eq(c[:hex])
      next unless step.is_a?(Engine::Game::G18OE::Step::HomeToken) && tokens.first.corporation.type == :minor

      expect(c[:price]).to eq(game.track_rights_cost(game.region_for_hex(city.hex)))
    end
    return if step.is_a?(Engine::Step::HomeToken) # also the engine's own home-token step (majors, regionals)

    expect(token[:price]).to eq(tokens.first.price)
    expect(token[:kind]).to eq("operating")
  end

  # What the view promised is what the engine did: the treasury grew by `treasury`,
  # the share price is the predicted one.
  def check_dividend(opt, entity, before)
    expect(opt[:price]).to eq(entity.share_price&.price)
    expect(entity.cash - before[:cash]).to eq(opt[:treasury])
    # #294: every holder got exactly the announced payout (rounded up per recipient), nobody else got money.
    # The last dividend of an operating round starts the next one, which pays the private companies' income to
    # the players (bot games now reach this): the cash comparison only holds while the round is still the same.
    return unless @game_for_check.round.equal?(before[:round])

    paid = opt[:payouts].to_h { |p| [p[:holder], p[:amount]] }
    before[:holders].each do |id, cash|
      next if id == entity.id

      holder = @game_for_check.players.find { |x| x.id == id } || @game_for_check.corporation_by_id(id)
      expect(holder.cash - cash).to eq(paid.fetch(id, 0)), "#{id}: got #{holder.cash - cash}, view said #{paid[id].inspect}"
    end
  end

  # #302: the run being paid out, as the Route step stored it; it never claims more than the revenue.
  def check_routes(dividend, game)
    expect(dividend[:routes].map { |r| r[:train] }).to eq(game.round.routes.map { |r| r.train.name })
    dividend[:routes].each { |r| expect(r[:hexes]).not_to be_empty }
    expect(dividend[:routes].sum { |r| r[:revenue] }).to be <= dividend[:revenue]
  end

  def check_train(train, step, entity, game)
    expect(train[:limit]).to eq(game.train_limit(entity))
    expect(train[:count]).to eq(entity.trains.size)
    expect(train[:must_buy]).to eq(step.must_buy_train?(entity) ? true : false)
    expect(train[:obligation]).to eq(active: game.train_obligation_active?, fulfilled: game.fulfilled_train_obligation?(entity))
    reserved = game.depot.depot_trains.find { |t| t.name == "2+2" && t.from_depot? }
    expect(train[:reserved]&.fetch(:price)).to eq(reserved&.price)
    expect(train[:shortfall]).to eq(train[:must_buy] && train[:cheapest_price] ? [train[:cheapest_price] - entity.cash, 0].max : 0)
    @short = true if train[:shortfall].positive?
  end

  # --- last run (#119) ---------------------------------------------------------------------------------

  # One corporation's last run in the JSON view: the train revenues add up, the hexes exist on the board
  # and the segments follow the hexes (#436: also over a sea crossing). Returns the number of routes checked.
  def check_last_run(run, game)
    run["routes"].each do |r|
      expect(r.keys.sort).to eq(%w[hexes name revenue segments stops train])
      expect(r["hexes"]).to all(satisfy { |id| game.hex_by_id(id) })
      expect(r["segments"].map { |s| s["hex"] }.chunk(&:itself).map(&:first)).to eq(r["hexes"].uniq) if r["segments"].any?
      expect(r["stops"].sum { |s| s["revenue"] }).to eq(r["revenue"])
    end
    expect(run["routes"].sum { |r| r["revenue"] }).to eq(run["revenue"])
    run["routes"].size
  end
end
