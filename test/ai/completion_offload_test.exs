defmodule AI.CompletionOffloadTest do
  use Fnord.TestCase, async: false

  @moduletag capture_log: true

  setup do
    # Ensure Services.TempFile can be mocked
    :meck.new(Services.TempFile, [:passthrough])

    on_exit(fn ->
      try do
        :meck.unload(Services.TempFile)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  test "small content is returned unchanged" do
    small = "hello"
    assert AI.Completion.maybe_offload_tool_output(small) == small
  end

  test "large content is offloaded and placeholder returned" do
    large = String.duplicate("A", 150_000)

    tmp = Path.join(File.cwd!(), "tmp_offload_test.txt")

    # Ensure a file exists at the path returned by mktemp! so chmod() succeeds
    if File.exists?(tmp), do: File.rm!(tmp)
    File.write!(tmp, "")

    :meck.expect(Services.TempFile, :mktemp!, fn -> tmp end)

    res = AI.Completion.maybe_offload_tool_output(large)

    # File should exist and contain the large content
    assert File.exists?(tmp)
    assert File.read!(tmp) == large

    # Result should be a placeholder string containing the path and preview
    assert String.contains?(res, tmp)
    assert String.contains?(res, "Preview:")

    File.rm!(tmp)
  end

  test "offload failure falls back to original content" do
    large = String.duplicate("B", 150_000)

    :meck.expect(Services.TempFile, :mktemp!, fn -> raise "boom" end)

    res = AI.Completion.maybe_offload_tool_output(large)

    assert res == large
  end
end
