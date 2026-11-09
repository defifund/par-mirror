# frozen_string_literal: true

class GetFloorTool < ApplicationTool
  tool_name "get_floor"
  description "Floor price walls of a token in the floor fee mode: the current wall per quote asset and the history of wall moves (the floor price only rises)."
  input_schema(
    properties: { chain: chain_schema, token: address_schema("Token address."), quote: address_schema("Only this quote asset.") },
    required: %w[chain token]
  )

  def self.payload(chain:, token:, quote: nil)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    token = address(token, "token")
    return token if token.is_a?(Hash)
    quote &&= address(quote, "quote")
    return quote if quote.is_a?(Hash)
    row = find_token(c, token)
    return row if row[:error]

    Par::Payouts.new(c).floor(row, quote:)
  end
end
