require "test_helper"

# End-to-end through the real Rack stack: Rails middleware -> ParMcpApp -> MCP transport -> tool.
# The test database is empty, so these check the protocol, the schemas and the error paths, not the numbers.
class McpTest < ActionDispatch::IntegrationTest
  test "initialize answers as par-mirror without a session id" do
    body = post_mcp("initialize", protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" })

    assert_response :success
    assert_equal "par-mirror", body.dig("result", "serverInfo", "name")
    assert_nil response.headers["Mcp-Session-Id"]
  end

  test "every tool is listed and marked read-only" do
    tools = post_mcp("tools/list").dig("result", "tools")

    assert_equal ParMcpApp::TOOLS.map(&:name_value).sort, tools.map { _1["name"] }.sort
    tools.each do |t|
      assert t.dig("annotations", "readOnlyHint"), "#{t['name']} should be read-only"
      assert_equal false, t.dig("annotations", "destructiveHint"), "#{t['name']} should not be destructive"
    end
  end

  test "list_chains returns the enabled chains" do
    payload = call_tool("list_chains")

    assert_equal Par::Chains.enabled.map(&:slug), payload["chains"].map { _1["chain"] }
  end

  test "a single chain is a list of one, not the chain struct's fields" do
    payload = call_tool("search_tokens", chain: "rh", limit: 5)

    assert_nil payload["error"]
    assert_equal 0, payload["total"]
    assert_equal({}, call_tool("get_stats", chain: "rh").fetch("stats").except("rh"))
  end

  test "schema violations are reported to the agent" do
    text = tool_text("get_token", chain: "doge", token: "0x" + "1" * 40)
    assert_match(/not one of/, text)

    text = tool_text("get_holders", chain: "rh", token: "0x123")
    assert_match(/does not match pattern/, text)
  end

  test "unknown tokens and bad short links come back as error payloads" do
    assert_match(/is not a par token on rh/, call_tool("get_token", chain: "rh", token: "0x" + "1" * 40)["error"])
    assert_match(/16-hex id/, call_tool("resolve_short_link", link: "hello")["error"])
  end

  test "requests beyond the per-IP budget get 429" do
    with_memory_cache do
      ParMcpApp::REQUESTS_PER_MINUTE.times { post_mcp("tools/list") }
      post_mcp("tools/list")

      assert_response :too_many_requests
    end
  end

  private

  def post_mcp(method, **params)
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method:, params: }.to_json,
                 headers: { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }
    JSON.parse(response.body)
  end

  def tool_text(name, **arguments) = post_mcp("tools/call", name:, arguments:).dig("result", "content", 0, "text")

  def call_tool(name, **arguments) = JSON.parse(tool_text(name, **arguments))

  # the test environment uses :null_store, which never counts
  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end
end
