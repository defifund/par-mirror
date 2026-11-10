# A token page lists its top 50 holders and counts them. Without this, Postgres scans every balance row of the
# chain for that (big tokens like $par), sorts, and competes with the indexer doing it; with it, both are a short
# index read. Partial: zero balances (sold out) are most rows and never shown.
class AddHolderRankIndexToBalances < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :balances, [ :chain_id, :token, :balance ], order: { balance: :desc }, where: "balance > 0",
              name: "index_balances_holders_rank", algorithm: :concurrently, if_not_exists: true
  end
end
