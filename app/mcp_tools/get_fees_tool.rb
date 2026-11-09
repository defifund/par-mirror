# frozen_string_literal: true

class GetFeesTool < ApplicationTool
  tool_name "get_fees"
  description "A token's trading fees: totals collected so far and fees still pending in the locker (read live from the chain, so it can take a few seconds)."
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
    return row if row[:error]

    Par::Queries.new(c).fees(row)
  end
end
