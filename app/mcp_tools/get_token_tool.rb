# frozen_string_literal: true

class GetTokenTool < ApplicationTool
  tool_name "get_token"
  description "Full details of one par token: markets and quote assets, fee mode and fee split, supply, price, market cap, volume, creator fees, holders, socials, and whether it was launched through this mirror."
  input_schema(
    properties: { chain: chain_schema, token: address_schema("Token address.") },
    required: %w[chain token]
  )

  def self.payload(chain:, token:)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    token = address(token, "token")
    return token if token.is_a?(Hash)

    row = find_token(c, token)
    row.is_a?(Hash) && row[:error] ? row : row.merge(url: token_url(row))
  end
end
