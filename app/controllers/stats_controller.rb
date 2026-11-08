class StatsController < ApplicationController
  def show
    @chain_tab = Par::Chains.enabled.map(&:slug).include?(params[:chain]) ? params[:chain] : "all"
    range = params[:range].presence || "30d"
    chains = @chain_tab == "all" ? Par::Chains.enabled : [Par::Chains.get(@chain_tab)]
    if @chain_tab == "all"
      @stats, @daily = Par::Queries.all_chains(range)
    else
      q = Par::Queries.new(chains.first)
      @stats = q.stats
      @daily = q.daily(range)
    end
    @syncs = SyncState.where(chain_id: chains.map(&:id))
    @buybacks = Par::Queries.new(Par::Chains.get(4663)).buybacks if @stats[:par] && Par::Chains.enabled_ids.include?(4663)
    @leaders = leaders(chains, @daily[:from], @daily[:to])
    @per_chain = Par::Chains.enabled.map { |c| [c, Par::Queries.new(c).stats] } if @chain_tab == "all"
  end

  private

  # top 10 per board across the selected chains, in USD
  def leaders(chains, from, to)
    boards = chains.map do |c|
      usd = Par::Pricing.new(c).ref_usd
      Par::Queries.new(c).leaders(from, to).transform_values { |rows| rows.map { _1.merge(valueUsd: _1[:valueEth] * usd) } }
    end
    %i[volume fees payouts].to_h { |k| [k, boards.flat_map { _1[k] }.sort_by { -_1[:valueUsd] }.first(10)] }
  end
end
