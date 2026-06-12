defmodule AI.CompletionOffloadTest do
  use Fnord.TestCase, async: true

  @moduletag capture_log: true

  test "small content is returned unchanged" do
    small = "hello"
    assert AI.Completion.maybe_offload_tool_output(small) == small
  end

  test "large content is offloaded and placeholder returned" do
    large = String.duplicate("A", 150_000)

    res = AI.Completion.maybe_offload_tool_output(large)

    # The placeholder names the temp file created by the tree's
    # Services.TempFile; extract the path from the message rather than
    # dictating it.
    assert [_, tmp] = Regex.run(~r/written to (\S+)\./, res)
    assert File.read!(tmp) == large
    assert String.contains?(res, "Preview:")
  end

  test "offload failure falls back to original content" do
    large = String.duplicate("B", 150_000)

    # Re-register the tree's Services.TempFile entry with a dead pid.
    # Services.Instance.whereis nil-checks liveness, so mktemp!'s fetch!
    # raises and maybe_offload_tool_output's rescue returns the original
    # content - the real service-unavailable failure path.
    {pid, ref} = spawn_monitor(fn -> :ok end)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end

    Services.Instance.register(Services.TempFile, pid)

    assert AI.Completion.maybe_offload_tool_output(large) == large
  end
end
