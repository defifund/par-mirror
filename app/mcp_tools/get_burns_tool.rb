# frozen_string_literal: true

class GetBurnsTool < ApplicationTool
  tool_name "get_burns"
  description "Burn rounds of a token in the burn fee mode: how much of the token the burn vault has destroyed and when. Amounts are raw (18 decimals)."
  input_schema(
    properties: { chain: chain_schema, token: address_schema("Token address."), limit: limit_schema(20, 100) },
    required: %w[chain token]
  )

  def self.payload(chain:, token:, limit: nil)
    c = resolve_chain(chain)
    return c if c.is_a?(Hash)
    token = address(token, "token")
    return token if token.is_a?(Hash)

    scope = Burn.where(chain_id: c.id, token:, from_addr: c.addr(:burn_vault))
    { token:, rounds: scope.count, lastAt: scope.maximum(:ts), totalBurned: scope.sum(:amount).to_i.to_s,
      items: scope.order(block_number: :desc, log_index: :desc).limit(clamp(limit, 20, 100))
                  .map { { amount: _1.amount.to_i.to_s, txHash: _1.tx_hash, timestamp: _1.ts } } }
  end
end
