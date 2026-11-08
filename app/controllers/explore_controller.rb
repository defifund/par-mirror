class ExploreController < ApplicationController
  TABS = { "trending" => "recentVolume", "mcap" => "marketCap", "new" => "createdAt", "volume" => "volume", "active" => "lastTradeAt" }.freeze
  PER_PAGE = 60

  def index
    @tab = TABS.key?(params[:tab]) ? params[:tab] : "trending"
    @page = [params[:page].to_i, 0].max
    @total, @rows = Par::LaunchRows.filter(Par::LaunchRows.for(current_chain),
                                           { q: params[:q], orderBy: TABS[@tab], limit: PER_PAGE, offset: @page * PER_PAGE })
    @sync = SyncState.find_by(chain_id: current_chain.id)
  end
end
