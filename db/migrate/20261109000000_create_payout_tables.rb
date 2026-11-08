# Holder-reward rounds (PairPadDisperse v1/v2), per-wallet payouts, and floor-vault walls.
# Indexed by a second cursor (sync_states.extras_cursor) so they backfill independently of the main replay.
class CreatePayoutTables < ActiveRecord::Migration[8.0]
  def change
    create_table :distributions do |t|
      t.integer :chain_id, null: false
      t.bigint :block_number, null: false
      t.integer :log_index, null: false
      t.string :tx_hash, null: false
      t.bigint :ts
      t.string :token, null: false # the launch
      t.string :asset, null: false # 0x0 = native
      t.string :sender
      t.bigint :round, null: false
      t.decimal :total, precision: 78, null: false
      t.integer :recipients, null: false
      t.integer :version, null: false # 1 = PairPadDisperse (token only), 2 = PairPadDisperseV2
      t.index %i[chain_id block_number log_index], unique: true
      t.index %i[chain_id token]
    end

    create_table :rewards do |t|
      t.integer :chain_id, null: false
      t.bigint :block_number, null: false
      t.integer :log_index, null: false
      t.string :tx_hash, null: false
      t.bigint :ts
      t.string :token, null: false
      t.string :asset, null: false
      t.string :owner, null: false
      t.decimal :amount, precision: 78, null: false
      t.index %i[chain_id block_number log_index], unique: true
      t.index %i[chain_id owner]
      t.index %i[chain_id token]
    end

    create_table :floor_walls do |t|
      t.integer :chain_id, null: false
      t.bigint :block_number, null: false
      t.integer :log_index, null: false
      t.string :tx_hash, null: false
      t.bigint :ts
      t.string :token, null: false
      t.string :quote, null: false
      t.integer :tick_lower, null: false
      t.integer :tick_upper, null: false
      t.decimal :liquidity, precision: 78, null: false
      t.decimal :quote_in_wall, precision: 78, null: false
      t.decimal :circulating, precision: 78, null: false
      t.index %i[chain_id block_number log_index], unique: true
      t.index %i[chain_id token quote]
    end

    add_column :sync_states, :extras_cursor, :bigint
  end
end
