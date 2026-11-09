require "net/http"

module Par
  # JSON-RPC over HTTP with a per-chain request rate ceiling and patient backoff on rate limits,
  # so a long backfill against a public node degrades to "slow" instead of failing.
  class Rpc
    class Error < StandardError
      attr_reader :code, :details, :data
      def initialize(code, message, data = nil)
        @code = code
        @details = message
        @data = data # revert data of a failed eth_call, when the node returns it
        super("RPC #{code}: #{message}")
      end
    end

    RATE_LIMIT = /rate limit|too many requests|request limit reached|reached .*limit/i
    TRANSIENT = /node error|header not found|upstream|timeout|timed out|temporarily unavailable|internal error|no backend|bad gateway/i

    # One rate limiter per chain for the whole process: the sync, quote refresh and trader backfill
    # share the public RPC's budget instead of each assuming it has all of it.
    Limiter = Struct.new(:lock, :next_at, :interval)
    LIMITERS = {}
    LIMITERS_LOCK = Mutex.new

    def initialize(chain)
      @chain = chain
      @uri = URI(chain.rpc)
      @limiter = LIMITERS_LOCK.synchronize { LIMITERS[chain.id] ||= Limiter.new(Mutex.new, 0.0, 1.0 / chain.rps) }
      @lock = @limiter.lock
      @id = 0
    end

    def request(method, params)
      attempt = 0
      loop do
        throttle
        body = { jsonrpc: "2.0", id: next_id, method:, params: }.to_json
        res = begin
          http.post(@uri.request_uri.presence || "/", body, "content-type" => "application/json", "user-agent" => "par-community-mirror")
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, OpenSSL::SSL::SSLError, SocketError => e
          Thread.current[:par_http] = nil
          raise if (attempt += 1) > 8
          sleep(2**[attempt, 5].min)
          next
        end
        limited = %w[429 503].include?(res.code) || (res.body.to_s[0, 400] =~ RATE_LIMIT && res.body.include?('"error"'))
        if limited && (attempt += 1) <= 12
          pause = 1.5 * 2**[attempt, 5].min
          @lock.synchronize { @limiter.next_at = now + pause }
          sleep pause
          next
        end
        json = begin
          JSON.parse(res.body)
        rescue JSON::ParserError
          raise Error.new(res.code, "non-JSON response") if (attempt += 1) > 8
          sleep(2**[attempt, 5].min)
          next
        end
        if (err = json["error"])
          msg = err["message"].to_s
          # public load balancers (publicnode "broker: node error", "header not found" behind the head …)
          # fail single requests now and then: retry those instead of restarting the whole range
          if msg =~ TRANSIENT && (attempt += 1) <= 8
            sleep(2**[attempt, 5].min)
            next
          end
          raise Error.new(err["code"], msg, err["data"].is_a?(String) ? err["data"] : err.dig("data", "data"))
        end
        return json["result"]
      end
    end

    def block_number = request("eth_blockNumber", []).to_i(16)
    def block_ts(n) = request("eth_getBlockByNumber", [hex(n), false])["timestamp"].to_i(16)
    def tx_from(hash) = request("eth_getTransactionByHash", [hash])&.dig("from")&.downcase
    def eth_call(to, data, block: "latest") = request("eth_call", [{ to:, data: }, block])
    def balance(addr) = request("eth_getBalance", [addr, "latest"]).to_i(16)

    # eth_call as `from` with `value`, optionally with a state override ({ address => { balance:, stateDiff: } }):
    # how trades are quoted without a real balance or approval
    def simulate(to:, data:, from:, value: 0, overrides: nil)
      call = { from:, to:, data:, value: hex(value) }
      request("eth_call", overrides ? [ call, "latest", overrides ] : [ call, "latest" ])
    end

    # decode a view call: types are the output types, e.g. ["string"] or ["(address,uint256)[]"]
    def call(to, signature, *args, returns:)
      Abi.decode(returns, eth_call(to, Abi.calldata(signature, *args)))
    end

    MULTICALL3 = "0xca11bde05977b3631167028862be2a173976ca11"

    # Many eth_calls in one request through Multicall3.aggregate3 (allowFailure = true).
    # calls: [[to, calldata_hex], ...] -> [[success, return_hex], ...]
    def multicall(calls, batch: 150)
      calls.each_slice(batch).flat_map do |slice|
        Abi.decode(["(bool,bytes)[]"], eth_call(MULTICALL3, aggregate3_calldata(slice))).first
      end
    end

    # typed convenience: [[to, signature, args, returns], ...] -> decoded outputs (nil when a call reverted)
    def multi_read(reads)
      results = multicall(reads.map { |to, sig, args, _| [to, Abi.calldata(sig, *args)] })
      results.zip(reads).map do |(ok, data), (_, _, _, returns)|
        next nil unless ok && data.size > 2
        Abi.decode(returns, data) rescue nil
      end
    end

    def get_logs(from:, to:, address: nil, topics: nil)
      filter = { fromBlock: hex(from), toBlock: hex(to) }
      filter[:address] = address if address
      filter[:topics] = topics if topics
      request("eth_getLogs", [filter])
    end

    # parallel map with a small thread pool (the throttle keeps the overall rate in check)
    def pmap(items, threads: 6)
      queue = Queue.new
      items.each_with_index { |x, i| queue << [x, i] }
      out = Array.new(items.size)
      errors = []
      [threads, items.size].min.times.map do
        Thread.new do
          Rails.application.executor.wrap do
            while (job = (queue.pop(true) rescue nil))
              out[job[1]] = yield(job[0])
            end
          end
        rescue => e
          errors << e
        end
      end.then do |pool|
        # let the workers' executor.wrap through while this thread waits: in development a pending
        # code reload would otherwise deadlock (the reloader waits for us, the workers for the reloader)
        ActiveSupport::Dependencies.interlock.permit_concurrent_loads { pool.each(&:join) }
      end
      raise errors.first if errors.any?
      out
    end

    private

    # aggregate3((address target, bool allowFailure, bytes callData)[])
    def aggregate3_calldata(calls)
      w = ->(n) { n.to_s(16).rjust(64, "0") }
      tuples = calls.map do |to, data|
        bytes = data.delete_prefix("0x")
        len = bytes.size / 2
        to.delete_prefix("0x").downcase.rjust(64, "0") + w.(1) + w.(0x60) + w.(len) + bytes.ljust(((len + 31) / 32) * 64, "0")
      end
      offsets, pos = [], calls.size * 32
      tuples.each { |t| offsets << pos; pos += t.size / 2 }
      Abi.selector("aggregate3((address,bool,bytes)[])") + w.(0x20) + w.(calls.size) + offsets.map { w.(_1) }.join + tuples.join
    end

    def hex(n) = "0x" + n.to_s(16)
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def next_id = @lock.synchronize { @id += 1 }

    def throttle
      wait = @lock.synchronize do
        t = [now, @limiter.next_at].max
        @limiter.next_at = t + @limiter.interval
        t - now
      end
      sleep wait if wait > 0
    end

    def http
      Thread.current[:par_http] ||= {}
      Thread.current[:par_http][@uri.host] ||= begin
        h = Net::HTTP.new(@uri.host, @uri.port)
        h.use_ssl = @uri.scheme == "https"
        h.open_timeout = 15
        h.read_timeout = 60
        h.keep_alive_timeout = 30
        h.start
        h
      end
    end
  end
end
