require "test_helper"

class Par::MirrorTagTest < ActiveSupport::TestCase
  TAG = Par::MirrorTag::HEX
  SEL = "0x12345678"
  word = ->(hex) { hex.rjust(64, "0") }

  test "finds the tag at the end of a 32-byte salt word" do
    salt = "ab" * 24 + TAG
    assert Par::MirrorTag.in_calldata?(SEL + word.("1") + salt + word.("2"))
  end

  test "ignores the tag bytes when they are not word-aligned like a salt" do
    shifted = "ab" * 20 + TAG + "cd" * 4
    refute Par::MirrorTag.in_calldata?(SEL + shifted)
  end

  test "untagged or empty input" do
    refute Par::MirrorTag.in_calldata?(SEL + "ab" * 32)
    refute Par::MirrorTag.in_calldata?(nil)
  end
end
