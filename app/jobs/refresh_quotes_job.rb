# Recurring: re-price non-par quote assets (and the USD anchor) through the on-chain pricer.
class RefreshQuotesJob < ApplicationJob
  queue_as :default
  def perform
    Par::Chains.enabled.each do |c|
      Par::Indexer.new(c).refresh_quotes
      Par::LaunchRows.changed!(c.id) # USD values in the launch rows
    end
  end
end
