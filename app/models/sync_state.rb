class SyncState < ApplicationRecord
  def chain = Par::Chains.get(chain_id)

  # percent of the chain's par history replayed so far
  def progress
    span = head_block.to_i - chain.deploy_block
    span.positive? ? ((cursor_block - chain.deploy_block) * 100.0 / span).clamp(0, 100) : 100.0
  end

  def lag = head_block.to_i - cursor_block
end
