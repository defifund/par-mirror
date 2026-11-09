# frozen_string_literal: true

# Unsigned transactions that move a creator's trading fees to their wallet. Two steps on-chain: fees accrue in the
# locked positions until someone calls collectFees (open to anyone), which splits them and credits the creator in
# PairPadFeeEscrow; the creator then claims from the escrow. Never signs or sends.
class BuildClaimFeesTool < ApplicationTool
  MAX_LAUNCHES = 25

  tool_name "build_claim_fees"
  description <<~TEXT.squish
    For a creator wallet: unsigned transactions that collect the trading fees still sitting in its launches' locked
    pools (collectFees, open to anyone) and claim what the fee escrow already holds for it (claim for the native asset,
    claimToken per token). If collect transactions are returned, send them first and call this tool again afterwards
    to claim what they moved. Holder rewards need no claim (they are paid out automatically). Nothing is signed or sent.
  TEXT
  input_schema(
    properties: { chain: chain_schema, wallet: address_schema("The creator fee recipient wallet.") },
    required: %w[chain wallet]
  )
  annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

  def self.payload(chain:, wallet:)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    wallet = address(wallet, "wallet")
    return wallet if wallet.is_a?(Hash)

    q = Par::Queries.new(c)
    mine = Par::LaunchRows.for(c).select { _1[:creatorFeeRecipient].to_s.downcase == wallet }
    return { chain: c.slug, wallet:, launches: 0, transactions: [], note: "This wallet is not the creator fee recipient of any par launch on #{c.name}." } if mine.empty?

    considered = mine.sort_by { -_1[:totalVolumeUsd].to_f }.first(MAX_LAUNCHES)
    collect = considered.filter_map do |row|
      pending = q.fees(row)[:pending]
      next unless pending.any? { _1[:amount0].to_i.positive? || _1[:amount1].to_i.positive? }

      locker = c.addr(row[:kind] == "multi" ? :multi_locker : :locker)
      QuoteTradeTool.tx_out(c, wallet, { to: locker, data: Par::Abi.calldata("collectFees(address)", row[:token]), value: 0 },
                            "Collect the fees accrued in #{row[:symbol]}'s locked pool#{row[:kind] == 'multi' ? 's' : ''} into the escrow")
    end

    esc = c.addr(:fee_escrow)
    held = q.claimable(wallet)
    claims = []
    if held[:native].to_i.positive?
      claims << QuoteTradeTool.tx_out(c, wallet, { to: esc, data: Par::Abi.calldata("claim()"), value: 0 },
                                      "Claim #{display(held[:native].to_i, 18)} #{c.reference[:native] ? c.reference[:symbol] : 'native'} from the fee escrow")
    end
    held[:tokens].each do |t|
      claims << QuoteTradeTool.tx_out(c, wallet, { to: esc, data: Par::Abi.calldata("claimToken(address)", t[:asset]), value: 0 },
                                      "Claim #{display(t[:amount].to_i, t[:decimals])} #{t[:symbol] || t[:asset]} from the fee escrow")
    end

    { chain: c.slug, wallet:, launches: mine.size, checked: considered.size,
      transactions: collect + claims,
      note: if collect.any?
              "Send the collect transactions first; when they confirm, call build_claim_fees again to claim what they moved#{claims.any? ? ' (the claims below cover what the escrow holds already)' : ''}."
            elsif claims.any? then "Sign and send these from #{wallet}."
            else "Nothing to collect or claim right now."
            end }
  end
end
