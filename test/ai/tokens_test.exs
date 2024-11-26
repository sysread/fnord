defmodule AI.TokensTest do
  use ExUnit.Case

  # From https://platform.openai.com/tokenizer
  @expected [
    10620,
    382,
    290,
    1058,
    395,
    722,
    1899,
    1966,
    316,
    3063,
    316,
    290,
    13765,
    328,
    1043,
    4931,
    13
  ]

  test "encode/1 <=> decode/1" do
    input = "Now is the time for all good men to come to the aid of their country."
    encoded = AI.Tokens.encode(input)

    assert encoded == @expected
    assert AI.Tokens.decode(encoded) == input
  end
end
