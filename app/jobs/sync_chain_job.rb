# Advances one chain's index for up to ~50 s, then re-enqueues itself.
# A Postgres advisory lock keeps it to one sync per chain: a duplicate (e.g. from the recurring
# KickSyncJob) exits immediately, and if the loop ever dies the next kick restarts it.
class SyncChainJob < ApplicationJob
  queue_as :sync

  def perform(chain_id)
    conn = ActiveRecord::Base.connection
    key = 0x7061_7200 + chain_id # "par" + chain id
    return unless conn.select_value("SELECT pg_try_advisory_lock(#{key})")

    behind = false
    begin
      ix = Par::Indexer.new(Par::Chains.get(chain_id))
      ix.run_until(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 50)
      ix.fill_traders(limit: 64) unless ix.state.backfilling
      behind = ix.state.cursor_block < ix.state.head_block.to_i
    rescue StandardError => e
      Rails.logger.error("[par #{chain_id}] sync error: #{e.class}: #{e.message}")
      sleep 5
    ensure
      conn.select_value("SELECT pg_advisory_unlock(#{key})")
    end
    self.class.set(wait: behind ? 0.seconds : 2.seconds).perform_later(chain_id)
  end
end
