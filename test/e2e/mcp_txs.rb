# Signs and sends, on a local anvil fork, the unsigned transactions this app hands out (MCP build_launch and
# build_trade: Par::Launching, Par::Trading), then checks what the chain did with them. Run through bin/fork-test,
# which starts the fork and points PAR_RPC_URL_<chain> at it; never against a real node. The wallet is a fresh random
# address that anvil impersonates and funds. Not anvil's dev accounts: on Robinhood Chain #0 carries an EIP-7702
# delegation that sweeps any ETH it receives, which makes every sell look like it paid nothing.
chain = Par::Chains.get(ENV.fetch("FORK_CHAIN", "rh"))
abort "refusing to run: #{chain.rpc} is not a local fork" unless chain.rpc.match?(%r{\Ahttp://127\.0\.0\.1:\d+\z})

RPC = Par::Rpc.new(chain)
ME = "0x#{SecureRandom.hex(20)}"
RPC.request("anvil_impersonateAccount", [ ME ])
RPC.request("anvil_setBalance", [ ME, "0x#{(10 * 10**18).to_s(16)}" ])
$fails = 0
def check(label, ok, detail = "")
  puts "#{ok ? 'PASS' : 'FAIL'}  #{ENV.fetch("FORK_CHAIN", "rh").ljust(4)} mcp #{label}#{" (#{detail})" unless detail.empty?}"
  $fails += 1 unless ok
end

def send_tx(tx)
  hash = RPC.request("eth_sendTransaction", [ { from: ME, to: tx[:to], data: tx[:data], value: "0x#{tx[:value].to_i.to_s(16)}", gas: "0xe4e1c0" } ])
  r = nil
  50.times { (r = RPC.request("eth_getTransactionReceipt", [ hash ])) ? break : sleep(0.2) }
  raise "no receipt for #{hash}" unless r
  [ r["status"] == "0x1", r ]
end

def bal(token) = RPC.call(token, "balanceOf(address)", ME, returns: [ "uint256" ]).first
def eth = RPC.balance(ME)
def gas_cost(r) = r["gasUsed"].to_i(16) * r["effectiveGasPrice"].to_i(16)
def fmt(raw) = (raw.to_f / 1e18).round(4).to_s

# --- launches (what build_launch returns) ---------------------------------------------------------------
second = chain.addr(:usdg) # the second quote asset of the two-market launch (USDG on Robinhood Chain, USDC on Base)
[ [ "launch, one market (PairPadRouter)", nil ], [ "launch, two markets (PairPadMultiRouter)", [ Par::Chains::ZERO, second ] ] ].each do |label, pairs|
  b = Par::Launching.new(chain, ME).build(name: "Fork check", symbol: "FORK", pairs:, dev_buy: 10**15)
  ok, r = send_tx(b[:tx])
  got = ok ? bal(b[:token]) : 0
  check(label, ok && got >= b[:min_tokens_out] && b[:min_tokens_out].positive?, "simulated #{fmt(b[:tokens_out])}, min #{fmt(b[:min_tokens_out])}, received #{fmt(got)}")
end

# a minimum above what the pool gives must make the whole launch revert (slippage_bps -10000 = min twice the simulation)
b = Par::Launching.new(chain, ME).build(name: "Fork check", symbol: "FORK", dev_buy: 10**15, slippage_bps: -10_000)
ok, = send_tx(b[:tx])
check("launch with an unreachable minimum reverts", !ok)

# --- trades (what quote_trade + build_trade return) ------------------------------------------------------
# the most traded single- and multi-market token of this chain in the local database
busiest = ->(kind) { Launch.where(chain_id: chain.id, kind:).joins("JOIN trades ON trades.token = launches.token AND trades.chain_id = launches.chain_id")
                           .group("launches.token").order(Arel.sql("count(*) desc")).limit(1).pick("launches.token") }
[ [ "single-market token", busiest.("single") ], [ "multi-market token", busiest.("multi") ] ].each do |kind, token|
  next check("#{kind}: none found in the local database", false) unless token

  t = Par::Trading.new(chain, token)
  amount = 10**15
  buy_out = out = t.quote("buy", amount, ME)
  min = out * 99 / 100
  before = bal(token)
  ok, = send_tx(t.build("buy", amount, min, ME))
  got = bal(token) - before
  check("buy #{kind} #{token[0, 10]}", ok && got >= min, "quoted #{fmt(out)}, min #{fmt(min)}, received #{fmt(got)}")
  next unless ok && got.positive?

  if (a = t.approval_needed("sell", got, ME))
    ok, = send_tx(a[:tx])
    check("approve #{kind} for the router", ok)
  end
  out = t.quote("sell", got, ME)
  min = out * 99 / 100
  before = eth
  ok, r = send_tx(t.build("sell", got, min, ME))
  back = eth - before + (ok ? gas_cost(r) : 0)
  check("sell #{kind} back", ok && back >= min, "status #{ok ? 'success' : 'reverted'}, quoted #{fmt(out)} ETH, min #{fmt(min)}, received #{fmt(back)}")

  ok, = send_tx(t.build("buy", amount, buy_out * 2, ME))
  check("buy #{kind} with an unreachable minimum reverts", !ok)
end

puts $fails.zero? ? "#{chain.slug} MCP transactions: all passed" : "#{chain.slug} MCP transactions: #{$fails} failed"
exit($fails.zero? ? 0 : 1)
