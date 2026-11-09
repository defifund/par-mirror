# frozen_string_literal: true

class GetTradesTool < ApplicationTool
  tool_name "get_trades"
  description "Recent trades, newest first, for one token, one wallet, or the whole chain. Amounts are raw integer strings (quoteAmount in the quote asset, tokenAmount in the token, both 18 decimals unless quoteDecimals says otherwise); valueEth/priceEth are in the chain's reference asset."
  input_schema(
    properties: {
      chain: chain_schema,
      token: address_schema("Only trades of this token."),
      wallet: address_schema("Only trades by this wallet."),
      limit: limit_schema(25, 100)
    },
    required: %w[chain]
  )

  def self.payload(chain:, token: nil, wallet: nil, limit: nil)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    token &&= address(token, "token")
    return token if token.is_a?(Hash)
    wallet &&= address(wallet, "wallet")
    return wallet if wallet.is_a?(Hash)

    # :later: missing trader addresses are filled by a background job, never by RPC calls inside this request
    { trades: Par::Queries.new(c).trades(token:, wallet:, limit: clamp(limit, 25, 100), fill: :later) }
  end
end
