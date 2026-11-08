# Recomputes the default stats view (all chains, 30 days) ahead of its expiry, so no visitor waits for it.
class WarmStatsJob < ApplicationJob
  queue_as :default

  def perform
    Rails.cache.write(StatsController.cache_key("all", "30d"), StatsController.page_data("all", "30d"), expires_in: StatsController::CACHE_TTL)
  end
end
