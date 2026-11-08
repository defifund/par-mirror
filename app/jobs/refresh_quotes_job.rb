# Recurring: re-price non-par quote assets (and the USD anchor) through the on-chain pricer.
class RefreshQuotesJob < ApplicationJob
  queue_as :default
  def perform = Par::Chains.enabled.each { Par::Indexer.new(_1).refresh_quotes }
end
