class StatsController < ApplicationController
  def show
    @stats = Par::Queries.new(current_chain).stats
    @daily = Par::Queries.new(current_chain).daily(params[:range].presence || "30d")
    @buybacks = Par::Queries.new(current_chain).buybacks if current_chain.addr(:par) != Par::Chains::ZERO
    @sync = SyncState.find_by(chain_id: current_chain.id)
  end
end
