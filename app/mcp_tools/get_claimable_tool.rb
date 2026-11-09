# frozen_string_literal: true

class GetClaimableTool < ApplicationTool
  tool_name "get_claimable"
  description "Creator fees a wallet can claim right now from the fee escrow, in the native asset and per token (read live from the chain)."
  input_schema(
    properties: { chain: chain_schema, owner: address_schema("Wallet address (the creator-fee recipient).") },
    required: %w[chain owner]
  )

  def self.payload(chain:, owner:)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    owner = address(owner, "owner")
    return owner if owner.is_a?(Hash)

    Par::Queries.new(c).claimable(owner)
  end
end
