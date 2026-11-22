# frozen_string_literal: true

module Engine
  module Game
    module G18OE
      # RB 14.4 Barclay, Bevan, Barclay and Tritton. The owner exercises one of three abilities with the private's one
      # marker: (1) re-set the par value of one owned regional or major that still has its par value marker (during a
      # stock action in any SR, or in that RR's OR), (2) put one share into custodianship, (3) keep one RR's share value
      # marker from moving DOWN for the rest of the SR. The private's choices on the owner's SR turn come from
      # Step::BuySellParShares (like Chris' remove_private/flip_private); (2) and (3) are also offered at the moment
      # another player buys or sells (Step::CustodyShare, Step::ProtectShare, as Step::ReserveShare for RB 8.4); (1)
      # in the OR is the private's choose_ability (Step::SpecialChoose). (1) and (2) remove the private at once
      # (RB 6.1), (3) at the end of the SR.
      module Bbbt
        BBBT_CUSTODY = 'bbbt_custody'
        BBBT_PROTECT = 'bbbt_protect'
        BBBT_REPAR = 'bbbt_repar'

        def bbbt_company
          company_by_id('BBBT')
        end

        # The choices of the private on its owner's SR turn: {choice => text}. The step has checked that the private may
        # act (owner's turn, not face down).
        def bbbt_choices(company)
          return {} unless company == bbbt_company && !@bbbt_used

          choices = {}
          @corporations.each do |corporation|
            bbbt_repar_cells(company, corporation).each do |cell|
              choices["#{BBBT_REPAR}:#{corporation.id}:#{cell.price}"] = "Re-Par #{corporation.name}: #{format_currency(cell.price)}"
            end
            choices["#{BBBT_CUSTODY}:#{corporation.id}"] = "Custodianship: share of #{corporation.name}" if bbbt_custody_share(corporation)
            choices["#{BBBT_PROTECT}:#{corporation.id}"] = "Protect #{corporation.name} from falling" if bbbt_protectable?(corporation)
          end
          choices
        end

        # RB 14.4 (1) while the owner's regional converts: any major par value for the new major; {choice => text}.
        def bbbt_repar_choices(company, corporation)
          return {} unless company == bbbt_company && !@bbbt_used && !company.closed? && company.owner == corporation.owner

          bbbt_major_par_cells.to_h { |cell| ["#{BBBT_REPAR}:#{cell.price}", "Re-Par: #{format_currency(cell.price)}"] }
        end

        # The major par values (the red convert-range cells of the share price table), lowest first.
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

        # RB 14.4 (1): the RR must have a marker on the Par Values section of the Info Board (RB 10.7: a major's until
        # the end of the SR in which it floats, a regional's until it expands). The par values of the RR's type, without
        # its current one.
        def bbbt_repar_cells(company, corporation)
          return [] unless company == bbbt_company && !@bbbt_used && !company.closed? && !face_down_private?(company)
          return [] if corporation.closed? || !company.owner&.player? || corporation.owner != company.owner

          cells =
            case corporation.type
            when :regional then corporation.floated? ? @stock_market.par_prices : []
            when :major then corporation.always_market_price ? [] : bbbt_major_par_cells
            else []
            end
          cells.reject { |cell| cell == corporation.par_price }.sort_by(&:price)
        end

        # A regional takes the new value as its par value (its share value is its par value, and the expansion follows
        # the new letter, RB 9.3); a major's par value marker moves, its share value marker stays (a brief effect).
        def bbbt_repar_now!(company, corporation, price)
          cell = bbbt_repar_cells(company, corporation).find { |c| c.price == price }
          raise GameError, "#{format_currency(price)} is not a par value #{corporation.name} can take" unless cell

          if corporation.type == :regional
            @stock_market.move(corporation, cell.coordinates)
            corporation.original_par_price = cell
          end
          corporation.par_price = cell
          @bbbt_used = true
          @log << "#{company.owner.name} re-sets the par value of #{corporation.name} to #{format_currency(cell.price)} " \
                  "(#{company.name}); #{company.name} leaves the game"
          company.close!
        end

        def bbbt_choice?(choice)
          choice.start_with?(BBBT_CUSTODY, BBBT_PROTECT, BBBT_REPAR)
        end

        def bbbt_exercise!(company, choice)
          kind, id, price = choice.split(':', 3)
          corporation = corporation_by_id(id)
          raise GameError, "Unknown corporation #{id}" unless corporation
          return bbbt_repar_now!(company, corporation, price.to_i) if kind == BBBT_REPAR

          if kind == BBBT_CUSTODY
            bbbt_custody!(company, corporation)
          else
            bbbt_protect!(company, corporation)
          end
          @bbbt_used = true
        end

        # RB 14.4 (2): a share of any RR still in the RR's treasury; of a regional only a secondary (25 %) share, and
        # only while both are in the treasury. Never the president's share.
        def bbbt_custody_share(corporation)
          return if corporation.closed? || !corporation.ipoed

          shares = corporation.ipo_shares.reject { |share| share.president || bbbt_custody?(share) }
          return if corporation.type == :regional && shares.size < 2

          shares.last
        end

        # In custody while the share is still in the treasury; bought or exchanged ends it.
        def bbbt_custody?(share)
          (@bbbt_custody ||= {}).key?(share) && share.owner == share.corporation.ipo_owner
        end

        # RB 14.4 (2): "This share may not be purchased by any other player."
        def bbbt_custody_blocks?(entity, bundle)
          return false unless bundle

          bundle.shares.any? { |share| bbbt_custody?(share) && @bbbt_custody[share] != entity }
        end

        def bbbt_custody!(company, corporation, share = bbbt_custody_share(corporation))
          raise GameError, "No share of #{corporation.name} can be put into custodianship" unless share

          owner = company.owner
          (@bbbt_custody ||= {})[share] = owner
          @log << "#{owner.name} puts a share of #{corporation.name} into custodianship (#{company.name}): " \
                  "reserved for #{owner.name}; #{company.name} leaves the game"
          # RB 6.1: the private leaves the game at once; its marker stays on the share until it is bought or exchanged
          # at a minor's merge, kept in @bbbt_custody.
          company.close!
        end

        # RB 14.4 (2), "at the moment another player is purchasing a share of stock in the owning player's RR": the
        # owner of the private if the purchase of `bundle` by `buyer` (a share from the treasury of a RR whose
        # president is the owner) could be stopped by custodianship, else nil.
        def bbbt_purchase_window_owner(buyer, bundle)
          company = bbbt_company
          return if company.nil? || company.closed? || @bbbt_used || face_down_private?(company)

          owner = company.owner
          corporation = bundle.corporation
          return unless owner&.player? && owner != buyer && corporation.owner == owner
          return if bundle.presidents_share || bundle.owner != corporation.ipo_owner || !bbbt_custody_share(corporation)

          owner
        end

        # The owner answers the window with "custody": the share being bought goes into custodianship.
        def bbbt_custody_at_purchase!(company, bundle)
          bbbt_custody!(company, bundle.corporation, bundle.shares.first)
          @bbbt_used = true
        end

        # RB 14.4 (3): the share value marker of any RR (also a foreign one) may not move DOWN for the rest of the SR.
        def bbbt_protectable?(corporation)
          !corporation.closed? && corporation.ipoed && !corporation.share_price.nil?
        end

        def bbbt_protect!(company, corporation)
          raise GameError, "#{corporation.name} cannot be protected" unless bbbt_protectable?(corporation)

          @bbbt_protected = corporation
          @log << "#{company.owner.name} protects the share value of #{corporation.name} from moving down for the " \
                  "rest of the stock round (#{company.name})"
        end

        def bbbt_exercised?
          !!@bbbt_used
        end

        # RB 14.4 (3), "at the moment another player is selling a share": the owner of the private if a sale of
        # `bundle` by another player would move the share value marker down and the private can still protect it.
        def bbbt_sale_window_owner(bundle)
          company = bbbt_company
          return if company.nil? || company.closed? || @bbbt_used || face_down_private?(company)

          owner = company.owner
          corporation = bundle.corporation
          return unless owner&.player? && owner != bundle.owner
          return if !bbbt_protectable?(corporation) || bbbt_protected?(corporation)

          owner if sell_movement(corporation).to_s.start_with?('down')
        end

        # The owner answers the window with "protect": same effect as the choice on the owner's own turn.
        def bbbt_protect_at_sale!(company, corporation)
          bbbt_protect!(company, corporation)
          @bbbt_used = true
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

        # RB 14.4 (3): "When the SR ends, remove the marker and the private certificate from play." (1) and (2) have
        # removed it already (RB 6.1).
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
