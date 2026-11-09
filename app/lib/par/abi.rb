# Minimal Solidity ABI codec: enough for par's events and view calls.
# Types are canonical strings: "uint256", "address", "string", "address[]", "(address,uint256)[]", ...
module Par
  module Abi
    module_function

    def keccak(str) = Digest::Keccak.hexdigest(str, 256)
    def selector(sig) = "0x" + keccak(sig)[0, 8]
    def topic(sig) = "0x" + keccak(sig)

    # ---- types ----
    # split "a,(b,c)[],d" at top-level commas
    def split_types(s)
      out, depth, cur = [], 0, +""
      s.each_char do |ch|
        depth += 1 if ch == "("
        depth -= 1 if ch == ")"
        if ch == "," && depth.zero?
          out << cur
          cur = +""
        else
          cur << ch
        end
      end
      out << cur unless cur.empty?
      out
    end

    def array_type?(t) = t.end_with?("]")
    def array_inner(t) = t.sub(/\[\d*\]\z/, "")
    def fixed_len(t) = t[/\[(\d+)\]\z/, 1]&.to_i
    def tuple?(t) = t.start_with?("(")
    def tuple_types(t) = split_types(t[1..-2])

    def dynamic?(t)
      return true if %w[string bytes].include?(t)
      return true if array_type?(t) && (fixed_len(t).nil? || dynamic?(array_inner(t)))
      return tuple_types(t).any? { |x| dynamic?(x) } if tuple?(t)
      false
    end

    def head_size(t)
      return 32 if dynamic?(t)
      return fixed_len(t) * head_size(array_inner(t)) if array_type?(t)
      return tuple_types(t).sum { |x| head_size(x) } if tuple?(t)
      32
    end

    # ---- decode ----
    def hex_bytes(hex) = [hex.delete_prefix("0x")].pack("H*")

    def decode(types, hex)
      decode_tuple(types, hex_bytes(hex), 0)
    end

    def decode_tuple(types, data, base)
      off = base
      types.map do |t|
        v = if dynamic?(t)
          ptr = word(data, off)
          decode_one(t, data, base + ptr)
        else
          decode_one(t, data, off)
        end
        off += head_size(t)
        v
      end
    end

    def word(data, off) = data.byteslice(off, 32).unpack1("H*").to_i(16)

    def decode_one(t, data, off)
      if array_type?(t)
        inner = array_inner(t)
        if (n = fixed_len(t))
          return decode_tuple([inner] * n, data, off)
        end
        n = word(data, off)
        return decode_tuple([inner] * n, data, off + 32)
      end
      return decode_tuple(tuple_types(t), data, off) if tuple?(t)

      case t
      when "address" then "0x" + data.byteslice(off + 12, 20).unpack1("H*")
      when "bool" then word(data, off) != 0
      when "string", "bytes"
        len = word(data, off)
        raw = data.byteslice(off + 32, len) || ""
        t == "string" ? raw.dup.force_encoding("UTF-8").scrub("") : "0x" + raw.unpack1("H*")
      when /\Abytes(\d+)\z/ then "0x" + data.byteslice(off, 32).unpack1("H*")[0, $1.to_i * 2]
      when /\Auint(\d*)\z/ then word(data, off)
      when /\Aint(\d*)\z/
        bits = ($1.empty? ? 256 : $1.to_i)
        v = word(data, off) & ((1 << bits) - 1)
        v >= (1 << (bits - 1)) ? v - (1 << bits) : v
      else raise ArgumentError, "unsupported abi type #{t}"
      end
    end

    # ---- encode one static word: address, uint, int, bool, bytes32 ----
    def encode_word(t, v)
      case t
      when "address" then v.to_s.delete_prefix("0x").downcase.rjust(64, "0")
      when "bool" then (v ? 1 : 0).to_s(16).rjust(64, "0")
      when /\Abytes32\z/ then v.to_s.delete_prefix("0x").ljust(64, "0")
      when /\Auint/ then Integer(v).to_s(16).rjust(64, "0")
      when /\Aint/ then (Integer(v) & ((1 << 256) - 1)).to_s(16).rjust(64, "0")
      else raise ArgumentError, "encode: unsupported #{t}"
      end
    end

    # call data for "name(type,type)": static args take the one-word path, anything with tuples, arrays,
    # bytes or strings goes through the full encoder
    def calldata(signature, *args)
      types = split_types(signature[/\((.*)\)\z/, 1])
      return selector(signature) + types.zip(args).map { |t, a| encode_word(t, a) }.join if types.none? { tuple?(_1) || array_type?(_1) || dynamic?(_1) }

      selector(signature) + encode(types, args)
    end

    # ---- encode (full: static and dynamic types, tuples, nested arrays) ----
    # encode(["(address,uint24)[]", "uint256"], [[["0x..", 3000]], 5]) -> hex without 0x
    def encode(types, values)
      heads = []
      tails = []
      tail_off = types.sum { |t| head_size(t) }
      types.zip(values).each do |t, v|
        if dynamic?(t)
          heads << encode_word("uint256", tail_off)
          enc = encode_one(t, v)
          tails << enc
          tail_off += enc.size / 2
        else
          heads << encode_one(t, v)
        end
      end
      heads.join + tails.join
    end

    def encode_one(t, v)
      if array_type?(t) # before tuple?: "(a,b)[]" also starts with "("
        inner = array_inner(t)
        body = encode([ inner ] * v.size, v)
        fixed_len(t) ? body : encode_word("uint256", v.size) + body
      elsif tuple?(t)
        encode(tuple_types(t), v)
      elsif t == "bytes" || t == "string"
        raw = t == "bytes" ? hex_bytes(v.to_s) : v.to_s.b
        hex = raw.unpack1("H*")
        encode_word("uint256", raw.bytesize) + hex.ljust((hex.size + 63) / 64 * 64, "0")
      else
        encode_word(t, v)
      end
    end

    # ---- events ----
    Event = Struct.new(:name, :signature, :topic0, :inputs) # inputs: [[name, type, indexed]]

    def event(decl)
      # "Swap(bytes32 indexed id, address indexed sender, int128 amount0, ...)"
      name = decl[/\A(\w+)\(/, 1]
      inputs = split_types(decl[/\((.*)\)\z/, 1]).map do |part|
        bits = part.strip.split(/\s+/)
        indexed = bits.include?("indexed")
        bits.delete("indexed")
        [bits[1]&.to_sym, bits[0], indexed]
      end
      sig = "#{name}(#{inputs.map { _2 }.join(',')})"
      Event.new(name, sig, topic(sig), inputs)
    end

    # log: {"topics"=>[...], "data"=>"0x.."} -> {name: value}
    def decode_log(ev, log)
      topics = log["topics"][1..]
      out = {}
      data_inputs = ev.inputs.reject { _3 }
      values = decode(data_inputs.map { _2 }, log["data"])
      data_inputs.each_with_index { |(n, _t, _), i| out[n] = values[i] }
      ev.inputs.select { _3 }.each_with_index do |(n, t, _), i|
        out[n] = dynamic?(t) ? topics[i] : decode([t], topics[i]).first
      end
      out
    end
  end
end
