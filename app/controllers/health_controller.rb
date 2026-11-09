# GET /health: one JSON verdict for the external monitor (a Cloudflare cron Worker polls it with a few pages).
# 200 when everything is fine, 503 with the failing checks otherwise. Unlike /up (Kamal's boot check) it covers
# what users notice: the indexer still advancing, the launch rows loading, and memory left on the shared host.
class HealthController < ApplicationController
  STALE_AFTER = 10.minutes # the indexer touches sync_states at least every minute (KickSyncJob)
  MAX_LAG = 2_000          # blocks behind head once caught up
  MIN_AVAILABLE_MB = 400   # host memory (a container's /proc/meminfo shows the host's)

  def show
    problems = []
    chains = SyncState.where(chain_id: Par::Chains.enabled_ids).to_h do |s|
      age = (Time.current - s.updated_at).round
      slug = s.chain.slug
      problems << "#{slug}: indexer idle for #{age / 60} min" if age > STALE_AFTER
      problems << "#{slug}: #{s.last_error}" if s.last_error.present?
      problems << "#{slug}: #{s.lag} blocks behind" if !s.backfilling && s.lag > MAX_LAG
      [ slug, { lag: s.lag, backfilling: s.backfilling, updatedSecondsAgo: age, error: s.last_error } ]
    end
    rows = Par::Chains.enabled.sum { Par::LaunchRows.for(_1).size }
    problems << "no launch rows" if rows.zero?
    mem = memory
    problems << "host memory low: #{mem[:availableMb]} MB available" if mem[:availableMb] && mem[:availableMb] < MIN_AVAILABLE_MB

    render json: { ok: problems.empty?, problems:, chains:, launchRows: rows, memory: mem, version: ENV["KAMAL_VERSION"].to_s[0, 7] },
           status: problems.empty? ? :ok : :service_unavailable
  end

  private

  def memory
    info = File.readlines("/proc/meminfo").to_h { |l| k, v = l.split(":"); [ k, v.to_i / 1024 ] }
    { availableMb: info["MemAvailable"], totalMb: info["MemTotal"], swapUsedMb: info["SwapTotal"].to_i - info["SwapFree"].to_i }
  rescue Errno::ENOENT
    {}
  end
end
