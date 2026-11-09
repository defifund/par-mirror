# frozen_string_literal: true

class GetHoldersTool < ApplicationTool
  tool_name "get_holders"
  description "Largest holders of a token, with raw balances (18 decimals). Pools, lockers and vaults are labelled or left out."
  input_schema(
    properties: { chain: chain_schema, token: address_schema("Token address."), limit: limit_schema(20, 100) },
    required: %w[chain token]
  )

  def self.payload(chain:, token:, limit: nil)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    token = address(token, "token")
    return token if token.is_a?(Hash)

    Par::Queries.new(c).holders(token, limit: clamp(limit, 20, 100))
  end
end
