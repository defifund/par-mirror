require "test_helper"

class Par::TraderTest < ActiveSupport::TestCase
  PM = "0x8366a39cc670b4001a1121b8f6a443a643e40951"
  USER = "0x" + "a" * 40
  ROUTER = "0x" + "b" * 40
  BOT = "0x" + "c" * 40

  def tr(i, from, to, value = 1) = [{ "logIndex" => "0x#{i.to_s(16)}" }, { from:, to:, value: }]
  def ix = @ix ||= Par::Indexer.new(Par::Chains.get(4663))

  test "direct buy and sell resolve to the wallet" do
    assert_equal USER, ix.trader_of([tr(7, PM, USER)], 6, true, PM)
    assert_equal USER, ix.trader_of([tr(5, USER, PM)], 6, false, PM)
  end

  test "router hops are followed" do
    assert_equal USER, ix.trader_of([tr(7, PM, ROUTER), tr(9, ROUTER, USER)], 6, true, PM)
    assert_equal USER, ix.trader_of([tr(2, USER, ROUTER), tr(4, ROUTER, PM)], 6, false, PM)
  end

  test "a routing hop (same amount out of and back into the PoolManager) defers to tx.from" do
    assert_nil ix.trader_of([tr(119, PM, ROUTER, 5), tr(120, ROUTER, PM, 5)], 121, false, PM)
  end

  test "an arbitrage bot that takes and settles in one tx stays the trader" do
    t = [tr(77, PM, BOT, 10), tr(78, BOT, PM, 9)]
    assert_equal BOT, ix.trader_of(t, 76, true, PM)
    assert_equal BOT, ix.trader_of(t, 79, false, PM)
  end

  test "no transfers -> nil" do
    assert_nil ix.trader_of(nil, 1, true, PM)
  end
end
