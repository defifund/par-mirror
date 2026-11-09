class StatsController < ApplicationController
  CACHE_TTL = 5.minutes

  def show
    @chain_tab = Par::Chains.enabled.map(&:slug).include?(params[:chain]) ? params[:chain] : "all"
    range = Par::Queries::RANGES.key?(params[:range]) ? params[:range] : "30d"
    chains = @chain_tab == "all" ? Par::Chains.enabled : [Par::Chains.get(@chain_tab)]
    @syncs = SyncState.where(chain_id: chains.map(&:id)) # live: the "history replayed" pills stay current
    # everything else is recomputed from the trades at most every CACHE_TTL per (chain tab, range)
    data = Rails.cache.fetch(self.class.cache_key(@chain_tab, range), expires_in: CACHE_TTL) { self.class.page_data(@chain_tab, range) }
    @stats, @daily, @buybacks, @leaders = data.values_at(:stats, :daily, :buybacks, :leaders)
    @per_chain = data[:per_chain]&.map { |id, st| [Par::Chains.get(id), st] }
    @computed_at = data[:at]
  end

  def self.cache_key(tab, range) = ["stats/page", tab, range, Par::Chains.enabled_ids]

  # everything on the page except the live sync pills; WarmStatsJob precomputes the default view
  def self.page_data(tab, range)
    chains = tab == "all" ? Par::Chains.enabled : [Par::Chains.get(tab)]
    stats, daily = if tab == "all"
                     Par::Queries.all_chains(range)
                   else
                     q = Par::Queries.new(chains.first)
                     [q.stats, q.daily(range)]
                   end
    buybacks = Par::Queries.new(Par::Chains.get(4663)).buybacks if stats[:par] && Par::Chains.enabled_ids.include?(4663)
    per_chain = Par::Chains.enabled.map { |c| [c.id, Par::Queries.new(c).stats] } if tab == "all"
    { stats:, daily:, buybacks:, leaders: leaders(chains, daily[:from], daily[:to]), per_chain:, at: Time.now.to_i }
  end

  # top 10 per board across the selected chains, in USD
  def self.leaders(chains, from, to)
    boards = chains.map do |c|
      usd = Par::Pricing.current(c).ref_usd
      Par::Queries.new(c).leaders(from, to).transform_values { |rows| rows.map { _1.merge(valueUsd: _1[:valueEth] * usd) } }
    end
    %i[volume fees payouts].to_h { |k| [k, boards.flat_map { _1[k] }.sort_by { -_1[:valueUsd] }.first(10)] }
  end
end
