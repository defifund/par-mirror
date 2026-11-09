# frozen_string_literal: true

class ListChainsTool < ApplicationTool
  tool_name "list_chains"
  description "List the chains this par mirror indexes, with each chain's reference asset and how far its index has caught up (indexed block vs chain head). Call this first to learn the valid `chain` values."
  input_schema(properties: {})

  def self.payload(**)
    states = SyncState.where(chain_id: Par::Chains.enabled_ids).index_by(&:chain_id)
    chains = Par::Chains.enabled.map do |c|
      s = states[c.id]
      { chain: c.slug, chainId: c.id, name: c.name, explorer: c.explorer,
        referenceAsset: c.reference.slice(:symbol, :decimals, :address),
        index: s && { headBlock: s.head_block, indexedBlock: s.cursor_block, lagBlocks: s.head_block.to_i - s.cursor_block.to_i,
                      backfillingHistory: s.backfilling, lastError: s.last_error } }
    end
    { site:, chains:, note: "Read-only data from the par community mirror. Amounts ending in Eth/Usd are decimals; other amounts are raw integer strings in the asset's smallest unit." }
  end
end
