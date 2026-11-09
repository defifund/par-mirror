# frozen_string_literal: true

class GetStatsTool < ApplicationTool
  tool_name "get_stats"
  description "Platform totals per chain: tokens launched, trades, volume, creator and protocol fees, holders and fee-mode split, including the last 24 hours. Omit chain for every chain; pass days to add a daily series."
  input_schema(
    properties: {
      chain: chain_schema(optional: true),
      days: { type: "integer", minimum: 0, maximum: 90, description: "Also return the last N days of daily volume and launches (default 0 = totals only)." }
    }
  )

  def self.payload(chain: nil, days: 0)
    chains = chains_for(chain)
    return chains if chains.is_a?(Hash)

    n = days.to_i.clamp(0, 90)
    stats = chains.to_h do |c|
      s = Par::Queries.new(c).stats
      s = n.zero? ? s.except(:daily, :launchesDaily) : s.merge(daily: s[:daily].last(n), launchesDaily: s[:launchesDaily].last(n))
      [ c.slug, s ]
    end
    { stats:, page: "#{site}/stats" }
  end
end
