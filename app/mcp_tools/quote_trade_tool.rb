# frozen_string_literal: true

# First half of a trade: simulate it against the chain and remember the result for 60 s under a quote id.
# build_trade turns a fresh quote into unsigned transactions; nothing is ever signed or sent here.
class QuoteTradeTool < ApplicationTool
  QUOTE_TTL = 60
  MAX_SLIPPAGE_BPS = 1_000
  IMPACT_WARN_PCT = 5

  tool_name "quote_trade"
  description <<~TEXT.squish
    Quote a buy or sell of a par token for a wallet: simulates the trade on-chain right now (price impact and LP fee
    included) and returns the expected output, a minimum output after slippage, the price impact against the last
    trade price, and whether an approval is needed. Buys spend the chain's reference asset (ETH on Robinhood Chain and
    Base, USDC on Arc); sells receive it. The quote is valid for 60 seconds: pass its quoteId to build_trade to get the
    unsigned transactions. Nothing is signed or sent. Not investment advice.
  TEXT
  input_schema(
    properties: {
      chain: chain_schema,
      token: address_schema("The par token's contract address."),
      side: { type: "string", enum: %w[buy sell], description: "buy = spend the reference asset; sell = spend the token." },
      amount: { type: "string", pattern: "^[0-9]+(\\.[0-9]+)?$",
                description: "Input amount as a decimal string: reference asset for a buy (e.g. \"0.01\" ETH, \"5\" USDC), tokens for a sell." },
      wallet: address_schema("The wallet that will sign: it pays, receives the output, and gives any approval."),
      slippage_bps: { type: "integer", minimum: 1, maximum: MAX_SLIPPAGE_BPS, description: "Slippage tolerance in basis points (default 100 = 1%, at most 1000)." },
      max_price_impact_pct: { type: "number", minimum: 0.1, maximum: 50,
                              description: "Refuse the quote when the price impact exceeds this (default 15)." }
    },
    required: %w[chain token side amount wallet]
  )
  annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

  def self.payload(chain:, token:, side:, amount:, wallet:, slippage_bps: 100, max_price_impact_pct: 15)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    token = address(token, "token")
    return token if token.is_a?(Hash)
    wallet = address(wallet, "wallet")
    return wallet if wallet.is_a?(Hash)
    row = find_token(c, token)
    return row if row.key?(:error)

    ref = c.reference
    in_dec, out_dec = side == "buy" ? [ ref[:decimals], row[:decimals] || 18 ] : [ row[:decimals] || 18, ref[:decimals] ]
    in_sym, out_sym = side == "buy" ? [ ref[:symbol], row[:symbol] ] : [ row[:symbol], ref[:symbol] ]
    amount_in = raw_amount(amount, in_dec, "amount")
    return amount_in if amount_in.is_a?(Hash)

    trade = Par::Trading.new(c, token)
    approval = trade.approval_needed(side, amount_in, wallet)
    if approval && side == "buy"
      # Arc: the router pulls USDC through an allowance a simulation cannot fake, so approve before quoting
      return { needsApprovalFirst: true, chain: c.slug, token: summary(row),
               message: "Buying on #{c.name} spends #{ref[:symbol]} through an allowance. Sign and send this approval, then call quote_trade again.",
               approvalTx: tx_out(c, wallet, approval[:tx], "Approve the par router to spend #{display(amount_in, in_dec)} #{ref[:symbol]}") }
    end

    out = trade.quote(side, amount_in, wallet)
    return { error: "the simulation returned nothing; this pool may have no liquidity for that size" } unless out.positive?

    bps = slippage_bps.to_i.clamp(1, MAX_SLIPPAGE_BPS)
    min_out = out * (10_000 - bps) / 10_000
    impact = price_impact(trade, side, amount_in, out, wallet)
    vs_last = vs_last_trade(side, row, amount_in, out, in_dec, out_dec)
    held = trade.input_balance(side, wallet)
    limit = max_price_impact_pct.to_f.clamp(0.1, 50)
    if impact && impact > limit
      return { error: "price impact #{impact.round(2)}% is above max_price_impact_pct #{limit}; trade a smaller amount or raise the limit",
               expectedOut: display(out, out_dec), priceImpactPct: impact.round(2) }
    end

    id = SecureRandom.hex(8)
    expires = Time.now.to_i + QUOTE_TTL
    Rails.cache.write("mcp/quote/#{id}", { chain: c.slug, token:, side:, amount_in:, min_out:, wallet:, expires:, out_dec:, out_sym: },
                      expires_in: (QUOTE_TTL + 30).seconds)

    { quoteId: id, expiresAt: Time.at(expires).utc.iso8601, chain: c.slug, token: summary(row), side:, wallet:,
      amountIn: { amount: display(amount_in, in_dec), symbol: in_sym, raw: amount_in.to_s },
      expectedOut: { amount: display(out, out_dec), symbol: out_sym, raw: out.to_s },
      minOut: { amount: display(min_out, out_dec), symbol: out_sym, raw: min_out.to_s, slippageBps: bps },
      priceImpactPct: impact&.round(2),
      lpFeePct: row[:poolFee].to_f / 10_000,
      vsLastTradePricePct: vs_last&.round(2),
      approvalNeeded: approval ? { asset: approval[:asset], spender: approval[:spender], amount: display(amount_in, in_dec) } : nil,
      route: trade.multi? ? "#{trade.routes.compact.size} of #{trade.markets.size} markets via PairPadMultiRouter" : "single market via PairPadRouter",
      warnings: warnings(row, impact, vs_last, side) +
                (held < amount_in ? [ "The wallet holds only #{display(held, in_dec)} #{in_sym}, less than this trade spends; it will fail as is." ] : []),
      next: "Call build_trade with this quoteId within #{QUOTE_TTL} seconds." }
  end

  # Size impact: this trade's rate against a probe 1/1000 its size, both simulated now with the same fees and
  # path, so the fee cancels out and a stale last-trade price cannot skew it
  def self.price_impact(trade, side, amount_in, out, wallet)
    probe = amount_in / 1_000
    return nil if probe.zero?

    probe_out = trade.quote(side, probe, wallet)
    return nil unless probe_out.positive?

    ((1 - (out.to_f / amount_in) / (probe_out.to_f / probe)) * 100).clamp(-100, 100)
  rescue Par::Trading::Error
    nil
  end

  # how far this fill is from the last recorded trade price (fees, size and any move since, all together)
  def self.vs_last_trade(side, row, amount_in, out, in_dec, out_dec)
    price = row[:lastPriceEth].to_f
    return nil unless price.positive?

    got = out.to_f / 10**out_dec
    spent = amount_in.to_f / 10**in_dec
    at_last = side == "buy" ? spent / price : spent * price
    ((got / at_last - 1) * 100).clamp(-100, 1_000)
  end

  def self.warnings(row, impact, vs_last, side)
    w = []
    w << "Price impact is #{impact.round(1)}%." if impact && impact > IMPACT_WARN_PCT
    w << "This fill is #{vs_last.round(1)}% from the last recorded trade price; the pool price has moved since or sits at a liquidity gap." if vs_last && vs_last.abs > 10
    w << "This token trades against a quote asset the original indexer did not verify (quoteRisk: wild)." if row[:quoteRisk] == "wild"
    w << "Fewer than 10 holders." if row[:holders].to_i < 10
    w << "The routers take no deadline: the minimum output is the only protection, so sign promptly." if side
    w
  end

  def self.tx_out(chain, from, tx, description)
    { chainId: chain.id, from:, to: tx[:to], data: tx[:data], value: tx[:value].to_s, valueHex: "0x#{tx[:value].to_s(16)}", description: }
  end
end
