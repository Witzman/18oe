# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # §14.4 Barclay, Bevan, Barclay and Tritton (workshop #78). The owner exercises one of three abilities;
      # this part has (2) custodianship and (3) protection of a share value marker against DOWN, both used on the
      # owner's own turn of a stock round (the private choices of Step::BuySellParShares). (1) re-setting a par
      # value is, by the owner's decision (#78/#466), used only when a regional of the owner converts to a major:
      # a free choice from the major par list instead of the letter mapping (deviates from the wording of §14.4,
      # which also allows the OR). The use at the moment another player acts is not built yet (see the issue).
      module Bbbt
        BBBT_CUSTODY = 'bbbt_custody'
        BBBT_PROTECT = 'bbbt_protect'
        BBBT_REPAR = 'bbbt_repar'

        def bbbt_company
          company_by_id('BBBT')
        end

        # The choices of the private for the stock round turn of its owner: {choice => text}. Called after the
        # step has checked that the private may act (owner's turn, no private used yet, not face down).
        def bbbt_choices(company)
          return {} unless company == bbbt_company && !@bbbt_used

          choices = {}
          @corporations.each do |corporation|
            choices["#{BBBT_CUSTODY}:#{corporation.id}"] = "Custodianship: share of #{corporation.name}" if bbbt_custody_share(corporation)
            choices["#{BBBT_PROTECT}:#{corporation.id}"] = "Protect #{corporation.name} from falling" if bbbt_protectable?(corporation)
          end
          choices
        end

        # §14.4 (1), owner's reading: while the owner's regional converts, any major par value; {choice => text}.
        def bbbt_repar_choices(company, corporation)
          return {} unless company == bbbt_company && !@bbbt_used && !company.closed? && company.owner == corporation.owner

          bbbt_major_par_cells.to_h { |cell| ["#{BBBT_REPAR}:#{cell.price}", "Re-Par: #{format_currency(cell.price)}"] }
        end

        # The major par values (the red convert-range cells of the share price table), highest value last.
        def bbbt_major_par_cells
          @stock_market.market.flatten.compact.select { |cell| cell.type == :convert_range }.sort_by(&:price)
        end

        def bbbt_repar_cell(price)
          bbbt_major_par_cells.find { |cell| cell.price == price }
        end

        # Returns the chosen par cell; the private is used up (closed) at once, the step applies the cell.
        def bbbt_repar!(company, corporation, choice)
          cell = bbbt_repar_cell(choice.split(':', 2).last.to_i)
          raise GameError, "#{choice} is not a major par value" unless cell

          @bbbt_used = true
          @log << "#{company.owner.name} re-sets the par value of #{corporation.name} to #{format_currency(cell.price)} " \
                  "as it converts to a major (#{company.name}); #{company.name} leaves the game"
          company.close!
          cell
        end

        def bbbt_choice?(choice)
          choice.start_with?(BBBT_CUSTODY, BBBT_PROTECT, BBBT_REPAR)
        end

        def bbbt_exercise!(company, choice)
          kind, id = choice.split(':', 2)
          corporation = corporation_by_id(id)
          raise GameError, "Unknown corporation #{id}" unless corporation

          if kind == BBBT_CUSTODY
            bbbt_custody!(company, corporation)
          else
            bbbt_protect!(company, corporation)
          end
          @bbbt_used = true
        end

        # §14.4 (2) and the paragraph shared with §14.5: a share of any RR still in the RR's treasury; of a regional
        # only a secondary (25 %) share, and only while both are in the treasury. Never the president's share.
        def bbbt_custody_share(corporation)
          return if corporation.closed? || !corporation.ipoed

          shares = corporation.ipo_shares.reject { |share| share.president || bbbt_custody?(share) }
          return if corporation.type == :regional && shares.size < 2

          shares.last
        end

        def bbbt_custody?(share)
          (@bbbt_custody ||= {}).key?(share) && share.owner == share.corporation.ipo_owner
        end

        # §14.4 (2): "This share may not be purchased by any other player."
        def bbbt_custody_blocks?(entity, bundle)
          return false unless bundle

          bundle.shares.any? { |share| bbbt_custody?(share) && @bbbt_custody[share] != entity }
        end

        def bbbt_custody!(company, corporation)
          share = bbbt_custody_share(corporation)
          raise GameError, "No share of #{corporation.name} can be put into custodianship" unless share

          (@bbbt_custody ||= {})[share] = company.owner
          @log << "#{company.owner.name} puts a share of #{corporation.name} into custodianship (#{company.name}): " \
                  "reserved for #{company.owner.name}"
        end

        # §14.4 (3): the share value marker of any RR (also a foreign one) may not move DOWN for the rest of the SR.
        def bbbt_protectable?(corporation)
          !corporation.closed? && corporation.ipoed && !corporation.share_price.nil?
        end

        def bbbt_protect!(company, corporation)
          raise GameError, "#{corporation.name} cannot be protected" unless bbbt_protectable?(corporation)

          @bbbt_protected = corporation
          @log << "#{company.owner.name} protects the share value of #{corporation.name} from moving down for the " \
                  "rest of the stock round (#{company.name})"
        end

        def bbbt_protected?(corporation)
          !@bbbt_protected.nil? && @bbbt_protected == corporation
        end

        # The sale still happens, the marker stays where it is.
        def sell_shares_and_change_price(bundle, allow_president_change: true, swap: nil, movement: nil)
          return super unless bbbt_protected?(bundle.corporation)

          @log << "#{bundle.corporation.name}'s share value does not move down (#{bbbt_company.name})"
          super(bundle, allow_president_change: allow_president_change, swap: swap, movement: :none)
        end

        # §14.4: "Exercising ability (2) or (3) closes this private at end of the SR."
        def bbbt_end_of_stock_round!
          @bbbt_protected = nil
          company = bbbt_company
          return unless @bbbt_used && company && !company.closed?

          @log << "#{company.name} leaves the game at the end of the stock round"
          company.close!
        end
      end
    end
  end
end
