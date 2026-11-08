class ExploreController < ApplicationController
  TABS = { "trending" => "recentVolume", "mcap" => "marketCap", "new" => "createdAt", "volume" => "volume", "active" => "lastTradeAt" }.freeze
  PER_PAGE = 60

  def index
    @tab = TABS.key?(params[:tab]) ? params[:tab] : "trending"
    @page = [params[:page].to_i, 0].max
    @chain_tab = Par::Chains.enabled.map(&:slug).include?(params[:chain]) ? params[:chain] : "all"
    @total, @rows = Par::LaunchRows.filter(Par::LaunchRows.across(@chain_tab),
                                           { q: params[:q], orderBy: TABS[@tab], limit: PER_PAGE, offset: @page * PER_PAGE })
    @syncs = SyncState.where(chain_id: Par::Chains.enabled_ids).index_by(&:chain_id)
  end
end
