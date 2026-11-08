# Recurring: make sure every enabled chain has its sync loop queued (duplicates are discarded).
class KickSyncJob < ApplicationJob
  queue_as :default
  def perform = Par::Chains.enabled_ids.each { SyncChainJob.perform_later(_1) }
end
