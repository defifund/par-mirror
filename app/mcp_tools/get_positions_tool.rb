# frozen_string_literal: true

class GetPositionsTool < ApplicationTool
  tool_name "get_positions"
  description "The par tokens a wallet holds (largest value first, with raw balance, value, cost and proceeds in the reference asset) and the tokens it launched. Omit chain to check every chain."
  input_schema(
    properties: { owner: address_schema("Wallet address."), chain: chain_schema(optional: true), limit: limit_schema(25, 100) },
    required: %w[owner]
  )

  def self.payload(owner:, chain: nil, limit: nil)
    owner = address(owner, "owner")
    return owner if owner.is_a?(Hash)
    chains = chains_for(chain)
    return chains if chains.is_a?(Hash)

    n = clamp(limit, 25, 100)
    per_chain = chains.to_h do |c|
      p = Par::Queries.new(c).positions(owner)
      held = p[:positions].sort_by { -_1[:valueUsd].to_f }
      [ c.slug, { held: held.size, positions: held.first(n).map { _1.except(:launch).merge(token: summary(_1[:launch])) },
                  launchedCount: p[:launched].size, launched: p[:launched].first(n).map { summary(_1) } } ]
    end
    { owner:, chains: per_chain }
  end
end
