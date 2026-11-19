# frozen_string_literal: true

module Oe
  # Which slice of the rules is verified (#130, notes/reference/rules-coverage.md). The engine enforces every
  # rule it knows, also outside the accepted slice; this tells the client when a game has left it, so that
  # odd behaviour is not mistaken for a UI error. The one place for the rule: extend SLICES with every slice
  # that gets accepted. Assumption (rule 10): the S1 step list is read from the S1 rows of rules-coverage.md.
  module Coverage
    SLICE = "S1"

    SLICES = {
      "S1" => {
        rounds: %w[Auction Concession Stock Operating],
        steps: %w[
          WaterfallAuction Concession HomeToken HomeHexConsent BuySellParShares ReserveShare TradeOffer
          Track Token Route Dividend BuyTrain IssueShares Bankrupt GoldenBellOrder
        ],
        train_phases: %w[2],
        major_phase: false,
      },
    }.freeze

    module_function

    # {slice:, verified:, reason:}; reason is nil while verified, else the first thing that left the slice:
    # "major_phase", "train_phase:<name>", "round:<Class>" or "step:<Class>".
    def for(game, slice: SLICE)
      rule = SLICES.fetch(slice)
      reason = leave_reason(game, rule)
      { slice: slice, verified: reason.nil?, reason: reason }
    end

    def leave_reason(game, rule)
      return "major_phase" if !rule[:major_phase] && game.major_phase?

      phase = game.phase.name.to_s
      return "train_phase:#{phase}" unless rule[:train_phases].include?(phase)

      round = last_name(game.round.class)
      return "round:#{round}" unless rule[:rounds].include?(round)

      step = game.finished ? nil : game.round.active_step
      return unless step

      name = last_name(step.class)
      "step:#{name}" unless rule[:steps].include?(name)
    end

    def last_name(klass)
      klass.name.split("::").last
    end
  end
end
