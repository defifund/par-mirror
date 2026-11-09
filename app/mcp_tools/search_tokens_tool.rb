# frozen_string_literal: true

class SearchTokensTool < ApplicationTool
  tool_name "search_tokens"
  description "Search par tokens by name, symbol or address, or list them sorted by volume, market cap, holders or launch time. Returns short summaries; use get_token for one token's full details."
  input_schema(
    properties: {
      chain: chain_schema(optional: true),
      query: { type: "string", description: "Part of the name or symbol (case-insensitive), or an exact token address." },
      deployer: address_schema("Only tokens launched by this address."),
      fee_mode: { type: "string", enum: %w[creator holders burn floor], description: "Only tokens whose trading fees go to the creator, to holders, to burns or to the floor." },
      order_by: { type: "string", enum: %w[createdAt lastTradeAt tradeCount volume marketCap recentVolume holders], description: "Sort key (default createdAt). recentVolume = last 24 hours." },
      ascending: { type: "boolean", description: "Sort ascending instead of descending." },
      limit: limit_schema(20, 100),
      offset: { type: "integer", minimum: 0, description: "Skip this many results (paging)." }
    }
  )

  def self.payload(chain: nil, query: nil, deployer: nil, fee_mode: nil, order_by: nil, ascending: false, limit: nil, offset: 0)
    chains = chains_for(chain)
    return chains if chains.is_a?(Hash)

    if deployer.present?
      deployer = address(deployer, "deployer")
      return deployer if deployer.is_a?(Hash)
    end
    rows = chains.flat_map { Par::LaunchRows.for(_1) }
    params = { q: query, deployer:, feeMode: fee_mode, orderBy: order_by, orderDirection: ascending ? "asc" : "desc",
               limit: clamp(limit, 20, 100), offset: offset.to_i }.with_indifferent_access
    total, page = Par::LaunchRows.filter(rows, params)
    { total:, offset: offset.to_i, tokens: page.map { summary(_1) } }
  end
end
