require "securerandom"

module Par
  # Sign-In with Ethereum (EIP-4361), verified with nothing but Ruby integers and keccak:
  # the server writes the message (domain, nonce, expiry), the wallet signs it with personal_sign,
  # and we recover the signer's address from the secp256k1 signature.
  # Plain EOAs only: smart-contract wallets (ERC-1271) would need an on-chain call.
  module Siwe
    P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
    N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    G = [0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
         0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8].freeze
    TTL = 10.minutes

    module_function

    def message(domain:, origin:, address:, chain_id:, now: Time.now.utc)
      nonce = SecureRandom.alphanumeric(16)
      text = <<~MSG.chomp
        #{domain} wants you to sign in with your Ethereum account:
        #{checksum(address)}

        Sign in to the par community mirror to edit your profile. This is free and sends no transaction.

        URI: #{origin}
        Version: 1
        Chain ID: #{chain_id.to_i}
        Nonce: #{nonce}
        Issued At: #{now.iso8601}
        Expiration Time: #{(now + TTL).iso8601}
      MSG
      { text:, address: address.downcase, expires: (now + TTL).to_i }
    end

    # address (lowercase 0x…) that produced a personal_sign signature over text, or nil
    def recover(text, signature)
      sig = signature.to_s.delete_prefix("0x")
      return nil unless sig.match?(/\A\h{130}\z/)
      r = sig[0, 64].to_i(16)
      s = sig[64, 64].to_i(16)
      v = sig[128, 2].to_i(16)
      v -= 27 if v >= 27
      return nil unless [0, 1].include?(v) && r.between?(1, N - 1) && s.between?(1, N - 1)

      bytes = text.b
      e = Digest::Keccak.digest("\x19Ethereum Signed Message:\n#{bytes.bytesize}".b + bytes, 256).unpack1("H*").to_i(16)
      y2 = (r.pow(3, P) + 7) % P
      y = y2.pow((P + 1) / 4, P)
      return nil unless y.pow(2, P) == y2
      y = P - y if y.odd? != v.odd?
      rinv = r.pow(N - 2, N)
      q = add(mul(s * rinv % N, [r, y]), mul((-e * rinv) % N, G))
      return nil unless q
      pub = [q[0].to_s(16).rjust(64, "0") + q[1].to_s(16).rjust(64, "0")].pack("H*")
      "0x" + Digest::Keccak.hexdigest(pub, 256)[-40..]
    rescue StandardError
      nil
    end

    # EIP-55 mixed-case address
    def checksum(address)
      a = address.to_s.downcase.delete_prefix("0x")
      h = Digest::Keccak.hexdigest(a, 256)
      "0x" + a.chars.each_with_index.map { |c, i| h[i].to_i(16) >= 8 ? c.upcase : c }.join
    end

    def add(a, b)
      return b unless a
      return a unless b
      if a[0] == b[0]
        return nil if (a[1] + b[1]) % P == 0
        l = 3 * a[0] * a[0] * (2 * a[1]).pow(P - 2, P) % P
      else
        l = (b[1] - a[1]) * ((b[0] - a[0]) % P).pow(P - 2, P) % P
      end
      x = (l * l - a[0] - b[0]) % P
      [x, (l * (a[0] - x) - a[1]) % P]
    end

    def mul(k, pt)
      acc = nil
      while k.positive?
        acc = add(acc, pt) if k.odd?
        pt = add(pt, pt)
        k >>= 1
      end
      acc
    end
  end
end
