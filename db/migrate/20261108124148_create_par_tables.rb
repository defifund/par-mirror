# Schema for the par community mirror. uint256 values are numeric(78,0) (exact, summable in SQL);
# addresses / hashes are lowercase hex strings; chain times are unix seconds (bigint).
class CreateParTables < ActiveRecord::Migration[8.1]
  U256 = { precision: 78, scale: 0 }.freeze

  def change
    create_table :sync_states do |t|
      t.integer :chain_id, null: false, index: { unique: true }
      t.bigint :cursor_block, null: false
      t.bigint :head_block
      t.boolean :backfilling, null: false, default: true
      t.string :last_error
      t.string :seeded_from
      t.datetime :quotes_refreshed_at
      t.timestamps
    end

    create_table :launches do |t|
      t.integer :chain_id, null: false
      t.string :token, null: false
      t.string :kind, null: false # single | multi
      t.string :factory, :locker, :deployer, :creator_fee_recipient, :protocol_fee_recipient
      t.integer :launch_config_id, :pool_fee, :tick_spacing, :base_fee_bps, :creator_tax_bps, :protocol_fee_share_bps
      t.string :name, :symbol
      t.integer :decimals, default: 18
      t.string :logo
      t.text :description
      t.jsonb :socials, default: {}
      t.decimal :supply, **U256
      t.decimal :burned, **U256, default: 0, null: false
      t.bigint :launched_at, :launch_block
      t.string :launch_tx
      t.timestamps
      t.index %i[chain_id token], unique: true
      t.index %i[chain_id launch_block]
      t.index %i[chain_id deployer]
      t.index %i[chain_id creator_fee_recipient]
    end

    create_table :markets do |t|
      t.integer :chain_id, null: false
      t.references :launch, null: false, foreign_key: true
      t.string :token, null: false
      t.integer :idx, null: false, default: 0
      t.string :pool_id, null: false
      t.string :pair_token, null: false
      t.string :quote_symbol
      t.integer :quote_decimals, default: 18
      t.boolean :token_is_c0, null: false
      t.decimal :position_id, **U256
      t.decimal :phantom_quote, **U256
      t.integer :tick_lower, :tick_upper
      t.decimal :token_amount, **U256, default: 0, null: false
      t.decimal :quote_raised, :tokens_sold, :volume_quote, **U256, default: 0, null: false
      t.integer :trade_count, null: false, default: 0
      t.decimal :creator_fees_quote, :creator_fees_token, :protocol_fees_quote, :protocol_fees_token, **U256, default: 0, null: false
      t.decimal :last_price_x18, precision: 78, scale: 0, default: 0, null: false
      t.bigint :last_trade_at
      t.index %i[chain_id pool_id], unique: true
      t.index %i[chain_id token idx], unique: true
    end

    create_table :trades do |t|
      t.integer :chain_id, null: false
      t.bigint :block_number, null: false
      t.integer :log_index, null: false
      t.string :tx_hash, null: false
      t.bigint :ts, null: false
      t.string :pool_id, :token, null: false
      t.integer :market, null: false, default: 0
      t.string :sender, :trader
      t.boolean :is_buy, null: false
      t.decimal :quote_amount, :token_amount, **U256, null: false
      t.integer :fee
      t.decimal :price_x18, **U256
      t.float :price_eth, :quote_eth, :value_eth
      t.index %i[chain_id block_number log_index], unique: true
      t.index %i[chain_id token ts]
      t.index %i[chain_id trader]
      t.index %i[chain_id tx_hash]
    end

    create_table :balances do |t|
      t.integer :chain_id, null: false
      t.string :token, :owner, null: false
      t.decimal :balance, **U256, null: false, default: 0
      t.index %i[chain_id token owner], unique: true
      t.index %i[chain_id owner]
    end

    create_table :fee_collections do |t|
      t.integer :chain_id, null: false
      t.bigint :block_number, null: false
      t.integer :log_index, null: false
      t.string :tx_hash
      t.bigint :ts
      t.string :token, null: false
      t.integer :market, null: false, default: 0
      t.string :currency0, :currency1
      t.decimal :protocol0, :protocol1, :creator0, :creator1, **U256, null: false
      t.index %i[chain_id block_number log_index], unique: true
      t.index %i[chain_id token]
    end

    create_table :burns do |t|
      t.integer :chain_id, null: false
      t.bigint :block_number, null: false
      t.integer :log_index, null: false
      t.string :tx_hash
      t.bigint :ts
      t.string :token, :from_addr, null: false
      t.decimal :amount, **U256, null: false
      t.index %i[chain_id block_number log_index], unique: true
      t.index %i[chain_id token]
    end

    create_table :quote_assets do |t|
      t.integer :chain_id, null: false
      t.string :pair_token, null: false
      t.string :symbol
      t.integer :decimals
      t.float :eth_per_unit
      t.datetime :priced_at
      t.index %i[chain_id pair_token], unique: true
    end

    create_table :block_timestamps do |t|
      t.integer :chain_id, null: false
      t.bigint :number, null: false
      t.bigint :ts, null: false
      t.index %i[chain_id number], unique: true
    end
  end
end
