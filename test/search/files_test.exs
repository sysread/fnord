defmodule Search.FilesTest do
  use ExUnit.Case, async: false

  test "new/1 builds a Search.Files struct" do
    search = Search.Files.new(query: "foo", limit: 5, detail: true)

    assert %Search.Files{query: "foo", limit: 5, detail: true} = search
  end
end
