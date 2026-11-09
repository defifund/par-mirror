# Two pricing bugs, fixed in Par::Indexer, and the rows they already wrote:
#
# 1. Quotes were priced by asking the on-chain pricer for 1e18 units of the reference asset. On Arc the reference is
#    6-decimal USDC, so that asked for 10^12 USDC and every non-USDC quote (CRCL, SPY, WETH ...) came out exactly
#    10^12 too cheap (the pricer is linear: checked against 1e6 on 2026-11-09). Scale the stored values back up.
# 2. price_x18 was an integer of raw quote units per whole token, which leaves one or two significant digits for
#    cheap tokens quoted in a 6-decimal stable. Give the columns 18 fractional digits; historic rows below 100 raw
#    units get the trade's execution price instead (quote_amount / token_amount, includes the pool fee), which is
#    closer than the truncated spot price.
class FixArcPricingAndPricePrecision < ActiveRecord::Migration[8.1]
  ARC = 5042
  USDC = "0x3600000000000000000000000000000000000000"

  def up
    change_column :trades, :price_x18, :decimal, precision: 78, scale: 18
    change_column :markets, :last_price_x18, :decimal, precision: 78, scale: 18, default: "0", null: false

    execute <<~SQL
      UPDATE quote_assets SET eth_per_unit = eth_per_unit * 1e12
      WHERE chain_id = #{ARC} AND pair_token <> '#{USDC}' AND eth_per_unit > 0
    SQL
    execute <<~SQL
      UPDATE trades SET quote_eth = quote_eth * 1e12, value_eth = value_eth * 1e12, price_eth = price_eth * 1e12
      WHERE chain_id = #{ARC} AND quote_eth > 0 AND quote_eth < 1
    SQL

    execute <<~SQL
      UPDATE trades t SET price_x18 = round(t.quote_amount * 1e18 / t.token_amount, 18),
                          price_eth = (t.quote_amount * 1e18 / t.token_amount) / power(10::numeric, m.quote_decimals) * t.quote_eth
      FROM markets m
      WHERE m.chain_id = t.chain_id AND m.pool_id = t.pool_id
        AND t.price_x18 < 100 AND t.token_amount > 0 AND t.quote_amount > 0
    SQL
    execute <<~SQL
      UPDATE markets m SET last_price_x18 = last.price_x18
      FROM (SELECT DISTINCT ON (chain_id, pool_id) chain_id, pool_id, price_x18 FROM trades
            ORDER BY chain_id, pool_id, block_number DESC, log_index DESC) last
      WHERE last.chain_id = m.chain_id AND last.pool_id = m.pool_id AND m.last_price_x18 > 0 AND m.last_price_x18 < 100
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
