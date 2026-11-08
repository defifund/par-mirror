class StatsController < ApplicationController
  def show
    @chain_tab = Par::Chains.enabled.map(&:slug).include?(params[:chain]) ? params[:chain] : "all"
    range = params[:range].presence || "30d"
    if @chain_tab == "all"
      @stats, @daily = Par::Queries.all_chains(range)
      @syncs = SyncState.where(chain_id: Par::Chains.enabled_ids)
    else
      chain = Par::Chains.get(@chain_tab)
      q = Par::Queries.new(chain)
      @stats = q.stats
      @daily = q.daily(range)
      @syncs = SyncState.where(chain_id: chain.id)
    end
    @buybacks = Par::Queries.new(Par::Chains.get(4663)).buybacks if @stats[:par] && Par::Chains.enabled_ids.include?(4663)
  end
end
