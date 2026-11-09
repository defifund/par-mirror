# frozen_string_literal: true

class GetHolderPayoutsTool < ApplicationTool
  tool_name "get_holder_payouts"
  description "Payout rounds of a token in the holders fee mode: what the original team's distributor sent to holders, round by round. With par.family offline these payouts have stopped."
  input_schema(
    properties: { chain: chain_schema, token: address_schema("Token address."), limit: limit_schema(20, 100) },
    required: %w[chain token]
  )

  def self.payload(chain:, token:, limit: nil)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    token = address(token, "token")
    return token if token.is_a?(Hash)

    Par::Payouts.new(c).distributions(token, limit: clamp(limit, 20, 100))
  end
end
