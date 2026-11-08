# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_08_140723) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "balances", force: :cascade do |t|
    t.integer "chain_id", null: false
    t.string "token", null: false
    t.string "owner", null: false
    t.decimal "balance", precision: 78, default: "0", null: false
    t.index ["chain_id", "owner"], name: "index_balances_on_chain_id_and_owner"
    t.index ["chain_id", "token", "owner"], name: "index_balances_on_chain_id_and_token_and_owner", unique: true
  end

  create_table "block_timestamps", force: :cascade do |t|
    t.integer "chain_id", null: false
    t.bigint "number", null: false
    t.bigint "ts", null: false
    t.index ["chain_id", "number"], name: "index_block_timestamps_on_chain_id_and_number", unique: true
  end

  create_table "burns", force: :cascade do |t|
    t.integer "chain_id", null: false
    t.bigint "block_number", null: false
    t.integer "log_index", null: false
    t.string "tx_hash"
    t.bigint "ts"
    t.string "token", null: false
    t.string "from_addr", null: false
    t.decimal "amount", precision: 78, null: false
    t.index ["chain_id", "block_number", "log_index"], name: "index_burns_on_chain_id_and_block_number_and_log_index", unique: true
    t.index ["chain_id", "token"], name: "index_burns_on_chain_id_and_token"
  end

  create_table "fee_collections", force: :cascade do |t|
    t.integer "chain_id", null: false
    t.bigint "block_number", null: false
    t.integer "log_index", null: false
    t.string "tx_hash"
    t.bigint "ts"
    t.string "token", null: false
    t.integer "market", default: 0, null: false
    t.string "currency0"
    t.string "currency1"
    t.decimal "protocol0", precision: 78, null: false
    t.decimal "protocol1", precision: 78, null: false
    t.decimal "creator0", precision: 78, null: false
    t.decimal "creator1", precision: 78, null: false
    t.index ["chain_id", "block_number", "log_index"], name: "idx_on_chain_id_block_number_log_index_db1340f292", unique: true
    t.index ["chain_id", "token"], name: "index_fee_collections_on_chain_id_and_token"
  end

  create_table "launches", force: :cascade do |t|
    t.integer "chain_id", null: false
    t.string "token", null: false
    t.string "kind", null: false
    t.string "factory"
    t.string "locker"
    t.string "deployer"
    t.string "creator_fee_recipient"
    t.string "protocol_fee_recipient"
    t.integer "launch_config_id"
    t.integer "pool_fee"
    t.integer "tick_spacing"
    t.integer "base_fee_bps"
    t.integer "creator_tax_bps"
    t.integer "protocol_fee_share_bps"
    t.string "name"
    t.string "symbol"
    t.integer "decimals", default: 18
    t.string "logo"
    t.text "description"
    t.jsonb "socials", default: {}
    t.decimal "supply", precision: 78
    t.decimal "burned", precision: 78, default: "0", null: false
    t.bigint "launched_at"
    t.bigint "launch_block"
    t.string "launch_tx"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "via_mirror", default: false, null: false
    t.index ["chain_id", "creator_fee_recipient"], name: "index_launches_on_chain_id_and_creator_fee_recipient"
    t.index ["chain_id", "deployer"], name: "index_launches_on_chain_id_and_deployer"
    t.index ["chain_id", "launch_block"], name: "index_launches_on_chain_id_and_launch_block"
    t.index ["chain_id", "token"], name: "index_launches_on_chain_id_and_token", unique: true
    t.index ["chain_id", "via_mirror"], name: "index_launches_on_chain_id_and_via_mirror"
  end

  create_table "markets", force: :cascade do |t|
    t.integer "chain_id", null: false
    t.bigint "launch_id", null: false
    t.string "token", null: false
    t.integer "idx", default: 0, null: false
    t.string "pool_id", null: false
    t.string "pair_token", null: false
    t.string "quote_symbol"
    t.integer "quote_decimals", default: 18
    t.boolean "token_is_c0", null: false
    t.decimal "position_id", precision: 78
    t.decimal "phantom_quote", precision: 78
    t.integer "tick_lower"
    t.integer "tick_upper"
    t.decimal "token_amount", precision: 78, default: "0", null: false
    t.decimal "quote_raised", precision: 78, default: "0", null: false
    t.decimal "tokens_sold", precision: 78, default: "0", null: false
    t.decimal "volume_quote", precision: 78, default: "0", null: false
    t.integer "trade_count", default: 0, null: false
    t.decimal "creator_fees_quote", precision: 78, default: "0", null: false
    t.decimal "creator_fees_token", precision: 78, default: "0", null: false
    t.decimal "protocol_fees_quote", precision: 78, default: "0", null: false
    t.decimal "protocol_fees_token", precision: 78, default: "0", null: false
    t.decimal "last_price_x18", precision: 78, default: "0", null: false
    t.bigint "last_trade_at"
    t.index ["chain_id", "pool_id"], name: "index_markets_on_chain_id_and_pool_id", unique: true
    t.index ["chain_id", "token", "idx"], name: "index_markets_on_chain_id_and_token_and_idx", unique: true
    t.index ["launch_id"], name: "index_markets_on_launch_id"
  end

  create_table "quote_assets", force: :cascade do |t|
    t.integer "chain_id", null: false
    t.string "pair_token", null: false
    t.string "symbol"
    t.integer "decimals"
    t.float "eth_per_unit"
    t.datetime "priced_at"
    t.index ["chain_id", "pair_token"], name: "index_quote_assets_on_chain_id_and_pair_token", unique: true
  end

  create_table "sync_states", force: :cascade do |t|
    t.integer "chain_id", null: false
    t.bigint "cursor_block", null: false
    t.bigint "head_block"
    t.boolean "backfilling", default: true, null: false
    t.string "last_error"
    t.string "seeded_from"
    t.datetime "quotes_refreshed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chain_id"], name: "index_sync_states_on_chain_id", unique: true
  end

  create_table "trades", force: :cascade do |t|
    t.integer "chain_id", null: false
    t.bigint "block_number", null: false
    t.integer "log_index", null: false
    t.string "tx_hash", null: false
    t.bigint "ts", null: false
    t.string "pool_id", null: false
    t.string "token", null: false
    t.integer "market", default: 0, null: false
    t.string "sender"
    t.string "trader"
    t.boolean "is_buy", null: false
    t.decimal "quote_amount", precision: 78, null: false
    t.decimal "token_amount", precision: 78, null: false
    t.integer "fee"
    t.decimal "price_x18", precision: 78
    t.float "price_eth"
    t.float "quote_eth"
    t.float "value_eth"
    t.index ["chain_id", "block_number", "log_index"], name: "index_trades_on_chain_id_and_block_number_and_log_index", unique: true
    t.index ["chain_id", "token", "ts"], name: "index_trades_on_chain_id_and_token_and_ts"
    t.index ["chain_id", "trader"], name: "index_trades_on_chain_id_and_trader"
    t.index ["chain_id", "tx_hash"], name: "index_trades_on_chain_id_and_tx_hash"
  end

  add_foreign_key "markets", "launches"
end
