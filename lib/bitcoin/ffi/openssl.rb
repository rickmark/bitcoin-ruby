# encoding: ascii-8bit

require 'ffi'
require 'openssl'

module Bitcoin
  # autoload when you need to re-generate a public_key from only its private_key.
  # ported from: https://github.com/sipa/bitcoin/blob/2d40fe4da9ea82af4b652b691a4185431d6e47a8/key.h
  module OpenSSL_EC # rubocop:disable Naming/ClassAndModuleCamelCase
    extend FFI::Library
    if FFI::Platform.windows?
      ffi_lib 'libeay32', 'ssleay32'
    else
      ffi_lib [
        'libssl.so.1.1.0', 'libssl.so.1.1',
        'libssl.so.1.0.0', 'libssl.so.10',
        '/Users/rickmark/.rbenv/versions/3.0.0/openssl/lib/libssl.1.1.dylib',
        'ssl'
      ]
    end

    NID_secp256k1 = 714 # rubocop:disable Naming/ConstantName
    POINT_CONVERSION_COMPRESSED = 2
    POINT_CONVERSION_UNCOMPRESSED = 4

    GROUP_NAME = 'secp256k1'

    COMPACT_SIGNATURE_LENGTH = 64

    GROUP_FIELD = OpenSSL::BN.new "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F", 16

    attach_function :RAND_poll, [], :int

    attach_function :BN_CTX_free, [:pointer], :int
    attach_function :BN_CTX_new, [], :pointer
    attach_function :BN_add, %i[pointer pointer pointer], :int
    attach_function :BN_bin2bn, %i[pointer int pointer], :pointer
    attach_function :BN_bn2bin, %i[pointer pointer], :int
    attach_function :BN_cmp, %i[pointer pointer], :int
    attach_function :BN_dup, [:pointer], :pointer
    attach_function :BN_free, [:pointer], :int
    attach_function :BN_mod_inverse, %i[pointer pointer pointer pointer], :pointer
    attach_function :BN_mod_mul, %i[pointer pointer pointer pointer pointer], :int
    attach_function :BN_mod_sub, %i[pointer pointer pointer pointer pointer], :int
    attach_function :BN_mul_word, %i[pointer int], :int
    attach_function :BN_new, [], :pointer
    attach_function :BN_rshift, %i[pointer pointer int], :int
    attach_function :BN_rshift1, %i[pointer pointer], :int
    attach_function :BN_set_word, %i[pointer int], :int
    attach_function :BN_sub, %i[pointer pointer pointer], :int
    attach_function :EC_GROUP_get_curve_GFp, %i[pointer pointer pointer pointer pointer], :int
    attach_function :EC_GROUP_get_degree, [:pointer], :int
    attach_function :EC_GROUP_get_order, %i[pointer pointer pointer], :int
    attach_function :EC_KEY_free, [:pointer], :int
    attach_function :EC_KEY_get0_group, [:pointer], :pointer
    attach_function :EC_KEY_get0_private_key, [:pointer], :pointer
    attach_function :EC_KEY_new_by_curve_name, [:int], :pointer
    attach_function :EC_KEY_set_conv_form, %i[pointer int], :void
    attach_function :EC_KEY_set_private_key, %i[pointer pointer], :int
    attach_function :EC_KEY_set_public_key,  %i[pointer pointer], :int
    attach_function :EC_POINT_free, [:pointer], :int
    attach_function :EC_POINT_mul, %i[pointer pointer pointer pointer pointer pointer], :int
    attach_function :EC_POINT_new, [:pointer], :pointer
    attach_function :EC_POINT_set_compressed_coordinates_GFp,
                    %i[pointer pointer pointer int pointer], :int
    attach_function :i2o_ECPublicKey, %i[pointer pointer], :uint
    attach_function :ECDSA_do_sign, %i[pointer uint pointer], :pointer
    attach_function :BN_num_bits, [:pointer], :int
    attach_function :ECDSA_SIG_free, [:pointer], :void
    attach_function :EC_POINT_add, %i[pointer pointer pointer pointer pointer], :int
    attach_function :EC_POINT_point2hex, %i[pointer pointer int pointer], :string
    attach_function :EC_POINT_hex2point, %i[pointer string pointer pointer], :pointer
    attach_function :d2i_ECDSA_SIG, %i[pointer pointer long], :pointer
    attach_function :i2d_ECDSA_SIG, %i[pointer pointer], :int
    attach_function :OPENSSL_free, :CRYPTO_free, [:pointer], :void

    def self.BN_num_bytes(ptr) # rubocop:disable Naming/MethodName
      (BN_num_bits(ptr) + 7) / 8
    end

    # resolve public from private key, using ffi and libssl.so
    # example:
    #   keypair = Bitcoin.generate_key; Bitcoin::OpenSSL_EC.regenerate_key(keypair.first) == keypair
    def self.regenerate_key(private_key)
      private_key = [private_key].pack('H*') if private_key.bytesize >= (32 * 2)
      private_key_hex = private_key.unpack('H*')[0]

      group = OpenSSL::PKey::EC::Group.new GROUP_NAME
      key = OpenSSL::PKey::EC.new(group)
      key.private_key = OpenSSL::BN.new(private_key_hex, 16)
      key.public_key = group.generator.mul(key.private_key)

      priv_hex = key.private_key.to_bn.to_s(16).downcase.rjust(64, '0')
      if priv_hex != private_key_hex
        raise 'regenerated wrong private_key, raise here before generating a faulty public_key too!'
      end

      [priv_hex, key.public_key.to_bn.to_s(16).downcase]
    end

    def self.ffi_bn_to_bn(bn)
      num_b = BN_num_bytes(bn)
      buf = FFI::MemoryPointer.new(:uint8, num_b)
      BN_bn2bin(bn, buf)
      value = buf.read_string(num_b).rjust(32, "\x00")
      OpenSSL::BN.new value, 2
    end

    def self.from_compressed_point(group, x, is_even)
      x_value = x.to_s(2).rjust(32, "\x00")
      prefix = is_even ? "\x02" : "\x03"

      encoded = OpenSSL::BN.new [ prefix, x_value ].join, 2
      OpenSSL::PKey::EC::Point.new(group, encoded)
    end

    # Given the components of a signature and a selector value, recover and
    # return the public key that generated the signature according to the
    # algorithm in SEC1v2 section 4.1.6.
    #
    # rec_id is an index from 0 to 3 that indicates which of the 4 possible
    # keys is the correct one. Because the key recovery operation yields
    # multiple potential keys, the correct key must either be stored alongside
    # the signature, or you must be willing to try each rec_id in turn until
    # you find one that outputs the key you are expecting.
    #
    # If this method returns nil, it means recovery was not possible and rec_id
    # should be iterated.
    #
    # Given the above two points, a correct usage of this method is inside a
    # for loop from 0 to 3, and if the output is nil OR a key that is not the
    # one you expect, you try again with the next rec_id.
    #
    #   message_hash = hash of the signed message.
    #   signature = the R and S components of the signature, wrapped.
    #   rec_id = which possible key to recover.
    #   is_compressed = whether or not the original pubkey was compressed.
    def self.recover_public_key_from_signature(message_hash, signature, rec_id, is_compressed)
      return nil if rec_id < 0 || signature.bytesize != 65

      signature = signature.dup.force_encoding Encoding::BINARY
      hash = message_hash.dup.force_encoding(Encoding::BINARY).ljust(32, "\0")

      r = OpenSSL::BN.new signature[1..32], 2
      s = OpenSSL::BN.new signature[33..64], 2

      i = rec_id / 2
      eckey = OpenSSL::PKey::EC.new GROUP_NAME
      eckey.group.point_conversion_form = :compressed if is_compressed

      group = OpenSSL::PKey::EC::Group.new GROUP_NAME
      x = group.order.dup
      x *= i
      x += r

      return nil if x >= GROUP_FIELD

      big_r = from_compressed_point(group, x, rec_id.even?)
      n = group.degree.dup
      e = OpenSSL::BN.new hash, 2
      e = e >> (8 - (n & 7)) if 8 * message_hash.bytesize > n

      e = 0.to_bn.mod_sub(e, group.order)
      rr = r.mod_inverse(group.order)
      sor = s.mod_mul(rr, group.order)
      eor = e.mod_mul(rr, group.order)
      big_q = big_r.mul(sor, eor)

      big_q.to_bn(is_compressed ? :compressed : :uncompressed).to_s(16).downcase
    end

    def self.bn_abs(bn)
      raise ArgumentError unless bn.is_a?(OpenSSL::BN)

      if bn.negative?
        -bn
      else
        bn
      end
    end

    # Regenerate a DER-encoded signature such that the S-value complies with the BIP62
    # specification.
    #
    def self.signature_to_low_s(signature_data)
      signature = OpenSSL::ASN1.decode signature_data

      # Calculate the lower s value
      r = OpenSSL::BN.new signature.value[0].value
      s = OpenSSL::BN.new signature.value[1].value

      raise EncodingError, 'r_value negative' if r.negative?
      raise EncodingError, 's_value negative' if s.negative?

      group = OpenSSL::PKey::EC::Group.new(GROUP_NAME)

      half_order = group.order >> 1

      s -= group.order if s > half_order

      encode_der_signature(r, s)
    end

    def self.encode_der_signature(r_value, s_value)
      signature = OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::Integer.new(r_value),
                                               OpenSSL::ASN1::Integer.new(s_value)])

      signature.to_der
    end

    def self.sign_compact(hash, private_key, public_key_hex = nil, pubkey_compressed = nil)
      msg32 = FFI::MemoryPointer.new(:uchar, 32).put_bytes(0, hash)
      new_hash = hash.dup.force_encoding(Encoding::BINARY).ljust(32, "\0")

      private_key = [private_key].pack('H*') if private_key.bytesize >= 64
      private_key_hex = private_key.unpack('H*')[0]

      public_key_hex ||= regenerate_key(private_key_hex).last
      pubkey_compressed ||= public_key_hex[0..1] != '04'

      eckey = EC_KEY_new_by_curve_name(NID_secp256k1)
      priv_key = BN_bin2bn(private_key, private_key.bytesize, BN_new())

      group = EC_KEY_get0_group(eckey)
      order = BN_new()
      ctx = BN_CTX_new()
      EC_GROUP_get_order(group, order, ctx)

      pub_key = EC_POINT_new(group)
      EC_POINT_mul(group, pub_key, priv_key, nil, nil, ctx)
      EC_KEY_set_private_key(eckey, priv_key)
      EC_KEY_set_public_key(eckey, pub_key)

      signature = ECDSA_do_sign(msg32, msg32.size, eckey)

      BN_free(order)
      BN_CTX_free(ctx)
      EC_POINT_free(pub_key)
      BN_free(priv_key)
      EC_KEY_free(eckey)

      buf = FFI::MemoryPointer.new(:uint8, 32)
      head = nil
      r, s = signature.get_array_of_pointer(0, 2).map do |i|
        BN_bn2bin(i, buf)
        buf.read_string(BN_num_bytes(i)).rjust(32, "\x00")
      end

      rec_id = nil
      if signature.get_array_of_pointer(0, 2).all? { |i| BN_num_bits(i) <= 256 }
        4.times do |i|
          head = [27 + i + (pubkey_compressed ? 4 : 0)].pack('C')
          recovered_key = recover_public_key_from_signature(
            msg32.read_string(32), [head, r, s].join, i, pubkey_compressed
          )
          if public_key_hex == recovered_key
            rec_id = i
            break
          end
        end
      end

      ECDSA_SIG_free(signature)

      [head, [r, s]].join if rec_id
    end

    def self.recover_compact(hash, signature)
      return false if signature.bytesize != 65
      msg32 = FFI::MemoryPointer.new(:uchar, 32).put_bytes(0, hash)

      version = signature.unpack('C')[0]
      return false if version < 27 || version > 34

      compressed = version >= 31
      version -= 4 if compressed

      recover_public_key_from_signature(msg32.read_string(32), signature, version - 27, compressed)
    end

    # lifted from https://github.com/GemHQ/money-tree
    def self.ec_add(point_0, point_1)
      group = OpenSSL::PKey::EC::Group.new(GROUP_NAME)

      point_0_hex = point_0.to_bn.to_s(16)
      point_0_pt = OpenSSL::PKey::EC::Point.new(group, OpenSSL::BN.new(point_0_hex, 16))
      point_1_hex = point_1.to_bn.to_s(16)
      point_1_pt = OpenSSL::PKey::EC::Point.new(group, OpenSSL::BN.new(point_1_hex, 16))

      sum_point = point_0_pt.add(point_1_pt)

      sum_point.to_bn.to_s(16)
    end

    def self.assert_asn1_signature(data)
      parsed_sig = OpenSSL::ASN1.decode data

      raise EncodingError, 'not an ASN1 sequence' unless parsed_sig.is_a?(OpenSSL::ASN1::Sequence)
      raise EncodingError, 'does not contain two items' unless parsed_sig.value.size == 2

      parsed_sig.value do |value|
        raise EncodingError, 'element is not an integer' unless value.is_a?(OpenSSL::ASN1::Integer)
        raise EncodingError, 'element integer is not a BN' unless value.value.is_a?(OpenSSL::BN)
        raise EncodingError, 'element is negative' if value.value.negative?
      end

      [ parsed_sig.value[0].value, parsed_sig.value[1].value ]
    end

    # repack signature for OpenSSL 1.0.1k handling of DER signatures
    # https://github.com/bitcoin/bitcoin/pull/5634/files
    def self.repack_der_signature(signature)
      return false if signature.empty?

      # New versions of OpenSSL will reject non-canonical DER signatures. de/re-serialize first.
      norm_der = FFI::MemoryPointer.new(:pointer)
      sig_ptr  = FFI::MemoryPointer.new(:pointer).put_pointer(
        0, FFI::MemoryPointer.from_string(signature)
      )

      norm_sig = d2i_ECDSA_SIG(nil, sig_ptr, signature.bytesize)

      derlen = i2d_ECDSA_SIG(norm_sig, norm_der)
      ECDSA_SIG_free(norm_sig)
      return false if derlen <= 0

      ret = norm_der.read_pointer.read_string(derlen)
      OPENSSL_free(norm_der.read_pointer)

      assert_asn1_signature ret

      ret
    end
  end
end
