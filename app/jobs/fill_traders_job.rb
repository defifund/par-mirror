# Resolves trade.trader (the transaction's `from`) for the given tx hashes, off the request path.
class FillTradersJob < ApplicationJob
  queue_as :default
  def perform(chain_id, hashes) = Par::Indexer.new(Par::Chains.get(chain_id)).fill_traders(hashes:)
end
