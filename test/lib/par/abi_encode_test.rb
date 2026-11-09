require "test_helper"

# The full encoder against viem's encodeFunctionData for the router calls MCP's build_trade makes
# (nested tuple arrays, an empty array, a negative int24). Vectors: test/fixtures/files/router_calldata_viem.txt.
class Par::AbiEncodeTest < ActiveSupport::TestCase
  WANT = Rails.root.join("test/fixtures/files/router_calldata_viem.txt").readlines.map(&:strip)
  K1 = [ "0x0000000000000000000000000000000000000000", "0x507b6f349a80114097a67b8b4677367acc15b220", 10_000, -200, "0x0000000000000000000000000000000000000000" ]
  K2 = [ "0x2ba0f44bdfc17fba30eda9cdbecb908ca45b043b", "0x3600000000000000000000000000000000000000", 3000, 0, "0x0000000000000000000000000000000000000000" ]
  DEAD = "0x000000000000000000000000000000000000dEaD"

  test "multi router buyWithEth with legs and nested hops matches viem" do
    legs = [ [ 0, [], 5 ], [ 2, [ [ K2, true ], [ K1, false ] ], 123_456_789 ] ]
    sig = "buyWithEth(address,#{Par::Trading::LEG}[],uint256,address)"
    assert_equal WANT[0], Par::Abi.calldata(sig, "0x990b66ad00000000000000000000000000000001", legs, 77, DEAD)
  end

  test "router sellToEth with a pool key and a hop array matches viem" do
    sig = "sellToEth(#{Par::Trading::KEY},bool,uint256,#{Par::Trading::HOP}[],uint256,address)"
    assert_equal WANT[1], Par::Abi.calldata(sig, K1, true, 10**21, [ [ K2, true ] ], 1, DEAD)
  end

  test "static-only signatures keep the one-word path" do
    assert_equal Par::Abi.selector("approve(address,uint256)") + DEAD.delete_prefix("0x").downcase.rjust(64, "0") + 5.to_s(16).rjust(64, "0"),
                 Par::Abi.calldata("approve(address,uint256)", DEAD, 5)
  end
end
