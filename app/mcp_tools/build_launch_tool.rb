# frozen_string_literal: true

# Unsigned launch transaction for an agent's own wallet (Par::Launching). The whole launch is simulated first, so a
# launch that would revert is reported here, and an opening buy gets a real minimum. Never signs or sends.
class BuildLaunchTool < ApplicationTool
  tool_name "build_launch"
  description <<~TEXT.squish
    Build an unsigned transaction that launches a new par token from the given wallet, optionally with an opening buy
    in the same transaction. The full supply goes into a permanently locked Uniswap pool; there is no team allocation.
    The launch is simulated first: you get the predicted token address, the launch fee, and for an opening buy the
    expected tokens and a minimum (slippage) encoded in the transaction. On Arc an opening buy is paid in USDC and needs
    an approval first, which is returned instead of the launch. Fee modes this mirror can launch are listed in the
    error if you pick another. Nothing is signed or sent; launching is irreversible once your wallet sends it.
  TEXT
  input_schema(
    properties: {
      chain: chain_schema,
      wallet: address_schema("The wallet that signs, pays the launch fee and becomes the creator."),
      name: { type: "string", minLength: 1, maxLength: 64, description: "Token name." },
      symbol: { type: "string", pattern: "^[A-Za-z0-9$._-]{1,16}$", description: "Ticker, 1-16 letters or digits." },
      description: { type: "string", maxLength: 1000, description: "Shown on the token page." },
      logo: { type: "string", pattern: "^(ipfs://|https://)\\S+$", description: "Image as ipfs://<cid> or an https:// URL." },
      socials: { type: "object", additionalProperties: false,
                 properties: Par::Launching::SOCIALS.to_h { [ _1.to_sym, { type: "string", pattern: "^https://\\S+$" } ] },
                 description: "Optional https links: twitter, telegram, discord, website, farcaster." },
      fee_mode: { type: "string", enum: %w[creator holders burn floor], description: "Where the creator share of trading fees goes (default creator: to the wallet)." },
      creator_tax_bps: { type: "integer", minimum: 0, maximum: 1000, description: "Extra creator fee on trades, in bps (default 0)." },
      quote_assets: { type: "array", maxItems: 5, items: address_schema("Quote asset."),
                      description: "Up to 5 assets the token trades against (default: the chain's reference, ETH or USDC). More than one makes a multi-market token." },
      dev_buy: { type: "string", pattern: "^[0-9]+(\\.[0-9]+)?$", description: "Optional opening buy in the reference asset, e.g. \"0.01\" ETH." },
      slippage_bps: { type: "integer", minimum: 1, maximum: 1000, description: "Slippage for the opening buy (default 100 = 1%)." }
    },
    required: %w[chain wallet name symbol]
  )
  annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

  def self.payload(chain:, wallet:, name:, symbol:, description: "", logo: "", socials: {}, fee_mode: "creator", creator_tax_bps: 0,
                   quote_assets: nil, dev_buy: nil, slippage_bps: 100)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    wallet = address(wallet, "wallet")
    return wallet if wallet.is_a?(Hash)
    pairs = Array(quote_assets).map { address(_1, "quote_assets") }
    return pairs.find { _1.is_a?(Hash) } if pairs.any?(Hash)
    ref = c.reference
    buy = dev_buy.present? ? raw_amount(dev_buy, ref[:decimals], "dev_buy") : 0
    return buy if buy.is_a?(Hash)

    r = Par::Launching.new(c, wallet).build(name: name.strip, symbol: symbol.strip.upcase, description:, logo:, socials: socials.to_h.transform_keys(&:to_s),
                                            fee_mode:, creator_tax_bps: creator_tax_bps.to_i, pairs:, dev_buy: buy, slippage_bps: slippage_bps.to_i.clamp(1, 1000))
    if (approval = r[:needs_approval_first])
      return { needsApprovalFirst: true, chain: c.slug,
               message: "The opening buy on #{c.name} is paid in #{ref[:symbol]} through an allowance. Sign and send this approval, then call build_launch again.",
               approvalTx: QuoteTradeTool.tx_out(c, wallet, approval, "Approve the par router to spend #{display(buy, ref[:decimals])} #{ref[:symbol]}") }
    end

    { chain: c.slug, wallet:, predictedToken: r[:token], predictedUrl: "#{site}/token/#{c.slug}/#{r[:token]}",
      launchFee: "#{display(r[:launch_fee], 18)} #{c.reference[:native] ? ref[:symbol] : "#{ref[:symbol]} (gas token)"}",
      markets: r[:pairs].size, router: r[:multi] ? "PairPadMultiRouter" : "PairPadRouter",
      openingBuy: buy.positive? ? { spend: "#{display(buy, ref[:decimals])} #{ref[:symbol]}", expectedTokens: display(r[:tokens_out], 18), minTokens: display(r[:min_tokens_out], 18) } : nil,
      transactions: [ QuoteTradeTool.tx_out(c, wallet, r[:tx], "Launch #{symbol.strip.upcase} on par#{buy.positive? ? ' with an opening buy' : ''}") ],
      notes: [ "The token address is predicted from the simulation; it is final once this exact transaction is mined.",
               "Launching is irreversible. The salt is fresh for each build, so build again rather than resending an old one." ] }
  end
end
