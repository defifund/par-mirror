require "test_helper"

# Every main page renders (on an empty index). Guards against a refactor leaving a page calling a method that
# no longer exists: on 2026-11-09 the explore page 500'd in production after LaunchRows.across was dropped.
class PagesTest < ActionDispatch::IntegrationTest
  test "explore, per-chain explore, stats and launch pages render" do
    [ "/", "/?chain=rh", "/?chain=base&tab=new", "/stats" ].each do |path|
      get path
      assert_response :success, "#{path} -> #{response.status}"
    end
  end

  test "an unknown token is a 404, not an error" do
    get "/token/rh/0x#{'0' * 39}1"
    assert_response :not_found
  end

  test "indexer API launches" do
    get "/idx/rh/launches"
    assert_response :success
  end
end
