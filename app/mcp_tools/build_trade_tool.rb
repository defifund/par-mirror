# frozen_string_literal: true

# Second half of a trade: turn a fresh quote into unsigned transactions for the caller's wallet to sign.
# Re-simulates first and refuses when the price has moved below the quote's minimum. Never signs or sends.
class BuildTradeTool < ApplicationTool
  tool_name "build_trade"
  description <<~TEXT.squish
    Turn a quoteId from quote_trade (at most 60 seconds old) into unsigned transactions: an exact-amount approval first
    when one is needed, then the trade, each as { chainId, from, to, data, value } for the wallet named in the quote to
    sign and send in order. The trade is simulated again first and refused if it would now return less than the quote's
    minimum. The minimum output is encoded in the transaction, so a later price move makes it revert instead of filling
    worse. This server never signs, holds keys or broadcasts.
  TEXT
  input_schema(
    properties: { quote_id: { type: "string", pattern: "^[0-9a-f]{16}$", description: "The quoteId returned by quote_trade." } },
    required: %w[quote_id]
  )
  annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

  def self.payload(quote_id:)
    q = Rails.cache.read("mcp/quote/#{quote_id}")
    return { error: "unknown or expired quoteId; call quote_trade again" } if q.nil? || Time.now.to_i > q[:expires]

    c = resolve_chain(q[:chain])
    trade = Par::Trading.new(c, q[:token])
    now = trade.quote(q[:side], q[:amount_in], q[:wallet])
    if now < q[:min_out]
      return { error: "the price moved: the trade would now return #{display(now, q[:out_dec])} #{q[:out_sym]}, " \
                      "below the quote's minimum of #{display(q[:min_out], q[:out_dec])}; call quote_trade again" }
    end

    Rails.cache.delete("mcp/quote/#{quote_id}") # one build per quote
    txs = []
    if (approval = trade.approval_needed(q[:side], q[:amount_in], q[:wallet]))
      txs << QuoteTradeTool.tx_out(c, q[:wallet], approval[:tx], "Approve the par router for exactly the amount this trade spends")
    end
    trade_tx = trade.build(q[:side], q[:amount_in], q[:min_out], q[:wallet])
    txs << QuoteTradeTool.tx_out(c, q[:wallet], trade_tx,
                                 "#{q[:side] == 'buy' ? 'Buy' : 'Sell'} on par; reverts if it would return less than " \
                                 "#{display(q[:min_out], q[:out_dec])} #{q[:out_sym]}")
    { chain: c.slug, wallet: q[:wallet], transactions: txs, simulatedOutNow: display(now, q[:out_dec]), minOut: display(q[:min_out], q[:out_dec]),
      note: "Sign and send these in order from #{q[:wallet]}#{txs.size > 1 ? ', waiting for the approval to confirm before the trade' : ''}." }
  end
end
