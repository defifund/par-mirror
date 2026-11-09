require "test_helper"

class Par::PricingTest < ActiveSupport::TestCase
  Q96 = 2**96

  def indexer(chain_id) = Par::Indexer.new(Par::Chains.get(chain_id))

  test "price_x18 keeps fractional digits for a cheap token quoted in a 6-decimal stable" do
    # 6.2853 raw USDC units per whole token (0.0000062853 USDC): sqrtPriceX96 for token = currency0
    ratio = 6.2853289446049436e-18
    sqrt = (Math.sqrt(ratio) * Q96).to_i
    px = indexer(5042).price_x18(sqrt, true)
    assert_kind_of BigDecimal, px
    assert_in_delta 6.2853289446, px.to_f, 1e-6
    assert_equal 0, indexer(5042).price_x18(0, true)
  end

  test "price_x18 inverts for token = currency1" do
    sqrt = (Math.sqrt(1 / 2.5e-12) * Q96).to_i # 2.5e-12 quote per token raw → 2.5e6 x18
    assert_in_delta 2_500_000, indexer(4663).price_x18(sqrt, false).to_f, 1
  end

  test "x18_s prints the API decimal string without trailing zeros" do
    assert_equal "6.2853", Par::Pricing.x18_s(BigDecimal("6.285300000000000000"))
    assert_equal "70457389518", Par::Pricing.x18_s(BigDecimal("70457389518.000000000000000000"))
    assert_equal "0", Par::Pricing.x18_s(0)
    assert_nil Par::Pricing.x18_s(nil)
  end

  test "quotes are priced with one whole unit of the chain's reference asset" do
    calls = []
    rpc = Object.new
    rpc.define_singleton_method(:call) { |*args, **| calls << args; [ 893_221 ] }
    ix = indexer(5042)
    ix.define_singleton_method(:rpc) { rpc }
    QuoteAsset.create!(chain_id: 5042, pair_token: "0x" + "ab" * 20, symbol: "EURC", decimals: 6)
    ix.send(:price_quote, "0x" + "ab" * 20, 6)
    assert_equal 10**6, calls.last.last, "Arc's reference is 6-decimal USDC"
    assert_in_delta 1.1195, QuoteAsset.find_by(chain_id: 5042, pair_token: "0x" + "ab" * 20).eth_per_unit, 1e-4
  end
end
