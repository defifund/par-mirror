# frozen_string_literal: true

class GetBuybacksTool < ApplicationTool
  tool_name "get_buybacks"
  description "Buybacks and burns of the $par token on a chain (paid from the protocol's share of fees)."
  input_schema(properties: { chain: chain_schema, limit: limit_schema(20, 100) }, required: %w[chain])

  def self.payload(chain:, limit: nil)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    return { error: "there is no $par token on #{c.slug}" } if c.addr(:par) == Par::Chains::ZERO

    r = Par::Queries.new(c).buybacks
    r.merge(items: r[:items].first(clamp(limit, 20, 100)))
  end
end
