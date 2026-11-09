# frozen_string_literal: true

class GetRewardsTool < ApplicationTool
  tool_name "get_rewards"
  description "Holder payouts one wallet has received, optionally for one token."
  input_schema(
    properties: { chain: chain_schema, owner: address_schema("Wallet address."), token: address_schema("Only payouts from this token."),
                  limit: limit_schema(50, 200) },
    required: %w[chain owner]
  )

  def self.payload(chain:, owner:, token: nil, limit: nil)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    owner = address(owner, "owner")
    return owner if owner.is_a?(Hash)
    token &&= address(token, "token")
    return token if token.is_a?(Hash)

    Par::Payouts.new(c).rewards(owner, token:, limit: clamp(limit, 50, 200))
  end
end
