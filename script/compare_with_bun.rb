# Cross-check the Rails index against two independent references up to the same block:
#   1. the Bun/TypeScript indexer (restore/indexer/data/4663.sqlite), built on par-sdk
#   2. the original par.family indexer, archived 2026-10-22 (archive/snapshots/<t>/api/rh/launches.json)
# Run with both indexes stopped at the same cursor:  bin/rails runner script/compare_with_bun.rb
require "open3"

SQLITE = ENV.fetch("BUN_DB", File.expand_path("../../indexer/data/4663.sqlite", __dir__))
ARCHIVE = Dir[File.expand_path("../../../archive/snapshots/*/api/rh/launches.json", __dir__)].max
CHAIN = 4663

def bun(sql)
  out, err, st = Open3.capture3("sqlite3", "-json", SQLITE, sql)
  abort err unless st.success?
  (out.strip.empty? ? [] : JSON.parse(out)).map { |row| row.transform_values { |v| v.nil? ? nil : (v.is_a?(Float) && v == v.floor && v.abs < 1e15 ? v.to_i.to_s : v.to_s) } }
end

$fail = 0
def check(label, ok, detail = nil)
  $fail += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FAIL'} #{label}#{detail ? " — #{detail}" : ''}"
end

bun_cursor = bun("SELECT value FROM meta WHERE key = 'cursor'").first["value"].to_i
rails_cursor = SyncState.find_by!(chain_id: CHAIN).cursor_block
puts "cursor: bun #{bun_cursor}, rails #{rails_cursor}"
abort "stop both at the same block first (PAR_STOP_AT_#{CHAIN}=#{bun_cursor})" unless bun_cursor == rails_cursor

# ---- launches ----
bl = bun("SELECT token, kind, deployer, creator_fee_recipient, name, symbol, created_block, burned, supply FROM launches").index_by { _1["token"] }
rl = Launch.where(chain_id: CHAIN).index_by(&:token)
check "launch set", bl.keys.sort == rl.keys.sort, "bun #{bl.size}, rails #{rl.size}, only-bun #{(bl.keys - rl.keys).first(3)}, only-rails #{(rl.keys - bl.keys).first(3)}"
fields = { "kind" => :kind, "deployer" => :deployer, "creator_fee_recipient" => :creator_fee_recipient, "name" => :name, "symbol" => :symbol,
           "created_block" => :launch_block, "burned" => :burned, "supply" => :supply }
fields.each do |bk, rk|
  bad = bl.count { |t, b| (r = rl[t]) && b[bk].to_s != (r.public_send(rk).is_a?(Numeric) ? r.public_send(rk).to_i.to_s : r.public_send(rk).to_s) }
  check "launches.#{bk}", bad.zero?, "#{bad} differ"
end

# ---- markets (aggregates) ----
bm = bun("SELECT * FROM markets").index_by { _1["pool_id"] }
rm = Market.where(chain_id: CHAIN).index_by(&:pool_id)
check "market set", bm.keys.sort == rm.keys.sort, "bun #{bm.size}, rails #{rm.size}"
%w[pair_token quote_decimals token_amount quote_raised tokens_sold volume_quote trade_count creator_fees_quote creator_fees_token protocol_fees_quote protocol_fees_token last_price_x18].each do |f|
  bad = bm.select { |pid, b| (r = rm[pid]) && b[f].to_s != (r[f].is_a?(Numeric) ? r[f].to_i.to_s : r[f].to_s) }
  check "markets.#{f}", bad.empty?, "#{bad.size} differ#{bad.any? ? ", e.g. #{bad.keys.first[0, 12]} bun=#{bad.values.first[f]} rails=#{rm[bad.keys.first][f]}" : ''}"
end

lt = bm.filter_map { |pid, b| (r = rm[pid]) && b["last_trade_at"] && (b["last_trade_at"].to_i - r.last_trade_at.to_i).abs }
check "markets.last_trade_at (both interpolated)", lt.max.to_i <= 30, "max diff #{lt.max}s"

# ---- trades ----
bt = bun("SELECT block, log_index, is_buy, quote_amount, token_amount, price_x18, ts FROM trades").index_by { "#{_1['block']}:#{_1['log_index']}" }
rt = Trade.where(chain_id: CHAIN).pluck(:block_number, :log_index, :is_buy, :quote_amount, :token_amount, :price_x18, :ts).index_by { "#{_1[0]}:#{_1[1]}" }
check "trade set", bt.keys.sort == rt.keys.sort, "bun #{bt.size}, rails #{rt.size}"
bad = bt.count { |k, b| (r = rt[k]) && [b["is_buy"].to_s == "1", b["quote_amount"], b["token_amount"], b["price_x18"]] != [r[2], r[3].to_i.to_s, r[4].to_i.to_s, r[5].to_i.to_s] }
check "trade side/amounts/price", bad.zero?, "#{bad} differ"
dts = bt.filter_map { |k, b| (r = rt[k]) && (b["ts"].to_i - r[6]).abs }
check "trade timestamps (rails samples every 10k blocks, bun every 2k)", dts.max.to_i <= 30,
      "max diff #{dts.max}s, mean #{(dts.sum.to_f / [dts.size, 1].max).round(2)}s, >5s: #{dts.count { _1 > 5 }}"

# ---- balances ----
sys = Par::Indexer.new(Par::Chains.get(CHAIN)).system_addresses
bb = bun("SELECT token, owner, balance FROM balances WHERE balance NOT IN ('0')").to_h { [[_1["token"], _1["owner"]], _1["balance"]] }
rb = Balance.where(chain_id: CHAIN).where.not(balance: 0).pluck(:token, :owner, :balance).to_h { [[_1, _2], _3.to_i.to_s] }
check "non-zero balance set", bb.keys.sort == rb.keys.sort, "bun #{bb.size}, rails #{rb.size}"
bad = bb.count { |k, v| rb[k] && rb[k] != v }
check "balance amounts", bad.zero?, "#{bad} differ"
neg = rb.count { |(_, o), v| v.start_with?("-") && !sys.include?(o) }
check "no negative balances", neg.zero?, "#{neg} negative"

# ---- burns, fee collections ----
bburn = bun("SELECT COUNT(*) n, SUM(CAST(amount AS REAL)) s FROM burns").first
check "burn rows", bburn["n"].to_i == Burn.where(chain_id: CHAIN).count, "bun #{bburn['n']}, rails #{Burn.where(chain_id: CHAIN).count}"
bf = bun("SELECT COUNT(*) n FROM fees").first["n"].to_i
check "fee collections", bf == FeeCollection.where(chain_id: CHAIN).count, "bun #{bf}, rails #{FeeCollection.where(chain_id: CHAIN).count}"

# ---- against the original indexer's archive (static launch fields) ----
if ARCHIVE
  arch = JSON.parse(File.read(ARCHIVE)).select { _1["createdBlock"].to_i <= rails_cursor }.index_by { _1["token"] }
  check "archive: launches in range", arch.keys.sort == rl.keys.sort, "archive #{arch.size}, rails #{rl.size}, only-archive #{(arch.keys - rl.keys).first(3)}"
  cmp = { "name" => :name, "symbol" => :symbol, "deployer" => :deployer, "createdBlock" => :launch_block, "createdAt" => :launched_at, "launchTx" => :launch_tx, "poolFee" => :pool_fee, "creatorTaxBps" => :creator_tax_bps }
  cmp.each do |ak, rk|
    bad = arch.select { |t, a| (r = rl[t]) && a[ak].to_s != r.public_send(rk).to_s }
    check "archive: #{ak}", bad.empty?, "#{bad.size} differ#{bad.any? ? ", e.g. #{bad.keys.first[0, 12]} archive=#{bad.values.first[ak]} rails=#{rl[bad.keys.first].public_send(rk)}" : ''}"
  end
  rpools = Market.where(chain_id: CHAIN).pluck(:token, :idx, :pool_id, :pair_token).group_by(&:first)
  bad = arch.count do |t, a|
    ms = a["markets"] || [{ "poolId" => a["poolId"], "pairToken" => a["pairToken"] }]
    mine = (rpools[t] || []).sort_by { _2 }.map { [_3, _4] }
    mine != ms.map { [_1["poolId"], _1["pairToken"]] }
  end
  check "archive: pool ids and pair tokens per market", bad.zero?, "#{bad} differ"
  # recipients may change after launch; the archive is newer than this cursor, so report only
  diff = arch.count { |t, a| (r = rl[t]) && a["creatorFeeRecipient"] != r.creator_fee_recipient }
  puts "info creator fee recipient differs from archive for #{diff} tokens (changed after block #{rails_cursor}?)"
end

puts($fail.zero? ? "\nALL CHECKS PASSED" : "\n#{$fail} CHECK(S) FAILED")
