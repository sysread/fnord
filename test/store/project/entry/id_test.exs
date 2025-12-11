defmodule Store.Project.Entry.IDTest do
  use ExUnit.Case, async: true
  alias Store.Project.Entry.ID

  @short "foo/bar.txt"
  test "to_key and from_key for short paths" do
    key = ID.to_key(@short)
    assert String.starts_with?(key, "r1-")
    assert {:ok, @short} = ID.from_key(key)
  end

  @long String.duplicate("a", 300)
  test "hash fallback when path too long" do
    key = ID.to_key(@long)
    assert String.starts_with?(key, "h1-")
    assert :error = ID.from_key(key)
  end
end
