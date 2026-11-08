require "test_helper"

# The ABI codec against real Robinhood Chain logs (first par launch, "Route Smoke", block 53900635),
# with expected values cross-checked against viem / par-sdk decoding of the same logs.
class Par::AbiTest < ActiveSupport::TestCase
  LOGS = JSON.parse(Rails.root.join("test/fixtures/files/route_smoke_logs.json").read)
  TOKEN = "0xd7eab0be61f9496ddce70c155b53797d456396c2"
  POOL = "0x8e24d02b896419f858b793ebcdf3a1277a30a29258c36cc48894fd8d683a3d9d"

  test "event topics match the canonical signatures" do
    assert_equal "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef", Par::Events::TRANSFER.topic0
    assert_equal "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f", Par::Events::SWAP.topic0
  end

  test "decodes TokenLaunched and LaunchPositionMinted" do
    launched = LOGS["launch"].find { _1["topics"][0] == Par::Events::TOKEN_LAUNCHED.topic0 }
    e = Par::Abi.decode_log(Par::Events::TOKEN_LAUNCHED, launched)
    assert_equal TOKEN, e[:token]
    assert_equal POOL, e[:poolId]
    assert_equal "0x0071ac8dbf95770c089fbd52af4bd5a63293b040", e[:deployer]
    assert_equal "0x6b12ec435f15f823ee3c550e9013123e4187429b", e[:pairToken]
    assert_equal 10_000, e[:poolFee]

    minted = LOGS["launch"].find { _1["topics"][0] == Par::Events::POSITION_MINTED.topic0 }
    m = Par::Abi.decode_log(Par::Events::POSITION_MINTED, minted)
    assert_equal(-887_270, m[:tickLower]) # negative int24
    assert_equal 52_810, m[:tickUpper]
    assert_equal 999_999_999_999_999_999_999_999_991, m[:tokenAmount]
  end

  test "decodes a v4 Swap with signed int128 amounts" do
    e = Par::Abi.decode_log(Par::Events::SWAP, LOGS["swap"].first)
    assert_equal POOL, e[:id]
    assert_equal(-734_792_043_137_956_354_921, e[:amount0])
    assert_equal 142_932_849_259_816_997_450_041, e[:amount1]
    assert_equal "0x73d84bdbb1983fa7ed8fcbce40bc308997ced120", e[:sender]
  end

  test "spot price from sqrtPriceX96 matches par-sdk priceX18FromSqrt" do
    e = Par::Abi.decode_log(Par::Events::SWAP, LOGS["swap"].first)
    ix = Par::Indexer.new(Par::Chains.get(4663))
    assert_equal 5_090_139_299_671_203, ix.price_x18(e[:sqrtPriceX96], false)
  end

  test "decodes dynamic outputs: strings, nested tuples and struct arrays" do
    # getTokenInfo() -> (address, string, string, (string x5))
    words = ->(*hex) { "0x" + hex.join }
    enc = Par::Abi
    addr = "0071ac8dbf95770c089fbd52af4bd5a63293b040".rjust(64, "0")
    str = ->(s) { s.bytesize.to_s(16).rjust(64, "0") + s.unpack1("H*").ljust(((s.bytesize + 31) / 32) * 64, "0") }
    # head: addr, off(logo)=0x80, off(desc), off(socials)
    logo, desc = str.("ipfs://x"), str.("hi")
    parts = ["", "", "", "https://a.b", ""].map { str.(_1) }
    offs, pos = [], 5 * 32
    parts.each { |p| offs << pos; pos += p.size / 2 }
    socials_tail = offs.map { _1.to_s(16).rjust(64, "0") }.join + parts.join
    o1 = 4 * 32
    o2 = o1 + logo.size / 2
    o3 = o2 + desc.size / 2
    data = words.(addr, o1.to_s(16).rjust(64, "0"), o2.to_s(16).rjust(64, "0"), o3.to_s(16).rjust(64, "0"), logo, desc, socials_tail)
    out = enc.decode(Par::Events::TOKEN_INFO, data)
    assert_equal "0x0071ac8dbf95770c089fbd52af4bd5a63293b040", out[0]
    assert_equal "ipfs://x", out[1]
    assert_equal "hi", out[2]
    assert_equal ["", "", "", "https://a.b", ""], out[3]
  end

  test "builds calldata for static arguments" do
    assert_equal "0x70a08231" + "00" * 12 + "0071ac8dbf95770c089fbd52af4bd5a63293b040",
                 Par::Abi.calldata("balanceOf(address)", "0x0071ac8dbf95770c089fbd52af4bd5a63293b040")
  end
end
