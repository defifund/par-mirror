# frozen_string_literal: true

class GetCandlesTool < ApplicationTool
  tool_name "get_candles"
  description "OHLC price candles for a token, built from its trades, oldest first. Prices are per whole token, in the quote asset and in the chain's reference asset (*Eth fields)."
  input_schema(
    properties: {
      chain: chain_schema,
      token: address_schema("Token address."),
      interval: { type: "string", enum: Api::IndexerController::INTERVALS.keys, description: "Candle size (default 5m)." },
      limit: limit_schema(100, 500),
      before: { type: "integer", description: "Only candles before this unix time (paging back)." },
      market: { type: "integer", minimum: 0, description: "Market index for multi-market tokens (default: the first)." }
    },
    required: %w[chain token]
  )

  def self.payload(chain:, token:, interval: "5m", limit: nil, before: nil, market: nil)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    token = address(token, "token")
    return token if token.is_a?(Hash)

    step = Api::IndexerController::INTERVALS[interval] || 300
    { interval:, candles: Par::Queries.new(c).candles(token, step:, limit: clamp(limit, 100, 500), before:, market:) }
  end
end
