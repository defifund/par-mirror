# /ipfs/<cid>[/path]: serves the copies pinned on the mirror's own node; anything else is handed
# to a public gateway that still has it.
class IpfsController < ApplicationController
  FALLBACK = "https://gateway.pinata.cloud/ipfs/".freeze

  def show
    cid = params[:cid]
    return head(:bad_request) unless Par::Ipfs.cid?(cid)
    if (res = Par::Ipfs.local_get(cid, params[:path]))
      response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
      response.headers["X-Content-Type-Options"] = "nosniff"
      type = res.content_type.to_s
      type = "application/octet-stream" unless type.start_with?("image/") # never serve HTML/JS from our origin
      send_data res.body, type:, disposition: "inline"
    else
      response.headers["Cache-Control"] = "public, max-age=300"
      redirect_to "#{FALLBACK}#{cid}#{"/#{params[:path]}" if params[:path].present?}", allow_other_host: true
    end
  end
end
