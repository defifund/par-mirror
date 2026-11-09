# GET /idx/:chain/events: text/event-stream, one "batch" event per indexed block range
# (par-sdk INTEGRATION.md A8). Follows sync_states.cursor_block; each stream lasts 5 minutes so a
# web thread is never held for long; EventSource reconnects by itself (and resumes via Last-Event-ID).
module Api
  class EventsController < ActionController::API
    include ActionController::Live

    POLL = 2
    LIFETIME = 300
    # each stream holds a web thread: keep most threads free for pages (browsers use /pulse instead)
    MAX_STREAMS = ENV.fetch("PAR_MAX_SSE_STREAMS", 1).to_i
    OPEN = Concurrent::AtomicFixnum.new(0)

    def index
      chain = Par::Chains.get(Par::Chains.id_for(params[:chain]))
      return head(:not_found) unless Par::Chains.enabled_ids.include?(chain.id)
      if OPEN.increment > MAX_STREAMS
        OPEN.decrement
        response.headers["Retry-After"] = "30"
        return render(plain: "too many event streams on this mirror, poll /idx/#{chain.id}/pulse instead", status: :service_unavailable)
      end
      @counted = true

      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"
      response.headers["access-control-allow-origin"] = "*"
      last = request.headers["Last-Event-ID"].presence&.to_i || SyncState.where(chain_id: chain.id).pick(:cursor_block).to_i
      response.stream.write("retry: 3000\n\n")
      deadline = Time.now + LIFETIME
      while Time.now < deadline
        cursor, head_block = SyncState.where(chain_id: chain.id).pick(:cursor_block, :head_block)
        if cursor.to_i > last
          range = (last + 1)..cursor
          data = { chainId: chain.id, fromBlock: range.begin, toBlock: range.end, head: head_block,
                   launches: Launch.where(chain_id: chain.id, launch_block: range).pluck(:token),
                   trades: Trade.where(chain_id: chain.id, block_number: range).count,
                   tokens: Trade.where(chain_id: chain.id, block_number: range).distinct.limit(200).pluck(:token) }
          response.stream.write("id: #{cursor}\nevent: batch\ndata: #{data.to_json}\n\n")
          last = cursor
        else
          response.stream.write(": ping\n\n")
        end
        sleep POLL
      end
    rescue ActionController::Live::ClientDisconnected, IOError
      nil
    rescue ArgumentError
      head :not_found
    ensure
      OPEN.decrement if @counted
      response.stream.close
    end
  end
end
