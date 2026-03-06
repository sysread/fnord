defmodule SafeJsonTest do
  use Fnord.TestCase, async: true

  # ---------------------------------------------------------------------------
  # Encode - valid data (should be identical to Jason)
  # ---------------------------------------------------------------------------

  test "encodes a simple map" do
    data = %{"key" => "value", "n" => 42}
    assert SafeJson.encode(data) == Jason.encode(data)
  end

  test "encodes with options (pretty: true)" do
    data = %{"a" => 1}
    assert SafeJson.encode(data, pretty: true) == Jason.encode(data, pretty: true)
  end

  test "encode! returns a string" do
    assert is_binary(SafeJson.encode!(%{"ok" => true}))
  end

  test "encode! with options" do
    result = SafeJson.encode!(%{"a" => 1}, pretty: true)
    assert result =~ "\"a\""
  end

  # ---------------------------------------------------------------------------
  # Encode - invalid UTF-8
  # ---------------------------------------------------------------------------

  test "encodes a map with invalid UTF-8 in values" do
    # 0xFF is never valid in UTF-8
    data = %{"key" => "hello\xFFworld"}
    assert {:ok, json} = SafeJson.encode(data)
    assert json =~ "hello"
    assert json =~ "world"
    # The replacement character U+FFFD encoded in JSON as \uFFFD or the raw
    # UTF-8 bytes (both are valid). Just confirm it round-trips.
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["key"] =~ "hello"
  end

  test "encodes a map with invalid UTF-8 in keys" do
    data = %{"bad\xFEkey" => "value"}
    assert {:ok, json} = SafeJson.encode(data)
    assert {:ok, _} = Jason.decode(json)
  end

  test "encode! does not raise on invalid UTF-8" do
    data = %{"key" => "hello\xFFworld"}
    assert is_binary(SafeJson.encode!(data))
  end

  # ---------------------------------------------------------------------------
  # Encode - nested structures
  # ---------------------------------------------------------------------------

  test "sanitizes deeply nested invalid UTF-8" do
    data = %{
      "a" => [
        %{"b" => "valid"},
        %{"c" => "bad\xE8byte"},
        ["nested\xFF"]
      ]
    }

    assert {:ok, json} = SafeJson.encode(data)
    assert {:ok, _} = Jason.decode(json)
  end

  test "sanitizes invalid UTF-8 in list at top level" do
    data = ["ok", "bad\xFFbyte", 42, nil, true]
    assert {:ok, json} = SafeJson.encode(data)
    assert {:ok, _} = Jason.decode(json)
  end

  # ---------------------------------------------------------------------------
  # Encode - passthrough for non-string scalars
  # ---------------------------------------------------------------------------

  test "passes through integers, floats, booleans, nil" do
    data = %{"i" => 1, "f" => 1.5, "b" => true, "n" => nil}
    assert SafeJson.encode(data) == Jason.encode(data)
  end

  # ---------------------------------------------------------------------------
  # Decode - pass-through
  # ---------------------------------------------------------------------------

  test "decode works identically to Jason" do
    json = ~s({"key": "value"})
    assert SafeJson.decode(json) == Jason.decode(json)
  end

  test "decode with options" do
    json = ~s({"key": "value"})
    assert SafeJson.decode(json, keys: :atoms) == Jason.decode(json, keys: :atoms)
  end

  test "decode! works identically to Jason" do
    json = ~s({"key": "value"})
    assert SafeJson.decode!(json) == Jason.decode!(json)
  end

  test "decode! raises on invalid JSON" do
    assert_raise Jason.DecodeError, fn ->
      SafeJson.decode!("not json")
    end
  end

  # ---------------------------------------------------------------------------
  # SafeJson.Serialize protocol
  # ---------------------------------------------------------------------------

  test "encodes a struct implementing SafeJson.Serialize" do
    memory = %Memory{
      scope: :global,
      title: "Test",
      slug: "test",
      content: "hello",
      topics: ["a"],
      embeddings: nil,
      inserted_at: "2026-01-01",
      updated_at: "2026-01-01"
    }

    assert {:ok, json} = SafeJson.encode(memory)
    assert {:ok, decoded} = SafeJson.decode(json)
    assert decoded["title"] == "Test"
    assert decoded["scope"] == "global"
  end

  test "sanitizes invalid UTF-8 inside a serializable struct" do
    memory = %Memory{
      scope: :global,
      title: "Bad\xFFtitle",
      slug: "test",
      content: "ok",
      topics: [],
      embeddings: nil,
      inserted_at: nil,
      updated_at: nil
    }

    assert {:ok, json} = SafeJson.encode(memory)
    assert {:ok, decoded} = SafeJson.decode(json)
    assert decoded["title"] =~ "Bad"
    assert decoded["title"] =~ "title"
  end
end
