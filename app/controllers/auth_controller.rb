# Sign-In with Ethereum: the server writes the message, the wallet signs it, we recover the signer.
class AuthController < ApplicationController
  rate_limit to: 20, within: 10.minutes, only: %i[message verify], with: -> { render json: { error: "too many attempts, wait a few minutes" }, status: :too_many_requests }

  # POST /api/auth/message { address, chainId } -> { message }
  def message
    addr = params[:address].to_s.downcase
    return render(json: { error: "bad address" }, status: :bad_request) unless addr.match?(/\A0x\h{40}\z/)
    chain_id = params[:chainId].to_i.positive? ? params[:chainId].to_i : Par::Chains.enabled_ids.first
    m = Par::Siwe.message(domain: request.host, origin: request.base_url, address: addr, chain_id:)
    session[:siwe] = m.stringify_keys
    render json: { message: m[:text] }
  end

  # POST /api/auth/verify { signature } -> { address }
  def verify
    m = session.delete(:siwe)
    return render(json: { error: "sign-in expired, try again" }, status: :unprocessable_entity) unless m.is_a?(Hash) && m["expires"].to_i > Time.now.to_i
    signer = Par::Siwe.recover(m["text"], params[:signature])
    unless signer && signer == m["address"]
      return render(json: { error: "the signature doesn't match this wallet (smart-contract wallets are not supported yet)" }, status: :unprocessable_entity)
    end
    reset_session # new session id once signed in
    session[:wallet] = { "address" => signer, "at" => Time.now.to_i }
    render json: { address: signer }
  end

  # DELETE /api/auth
  def destroy
    reset_session
    head :no_content
  end
end
