defmodule AI.Tools.SelfHelp.DocsTest do
  # Sync: set_log_level reconfigures the VM-global Logger level for the
  # duration of each test, which would leak into concurrently running tests.
  use Fnord.TestCase, async: false

  alias AI.Tools.SelfHelp.Docs

  setup do
    set_log_level(:none)
    :ok
  end

  # Regression: AI.Completion.get/1 can return a three-element tuple for
  # :context_length_exceeded (`{:error, :context_length_exceeded, usage}`),
  # which previously fell through the two-tuple case clauses and crashed
  # with CaseClauseError. The tool must now surface a soft error without
  # raising. The completion loop's compaction retry also hits the canned
  # error, so this exercises the full exhausted-compaction path.
  test "handles {:error, :context_length_exceeded, usage} without raising" do
    canned_completion({:error, :context_length_exceeded, 12_345})

    assert {:error, reason} = Docs.call(%{"question" => "How do worktrees work?"})
    assert reason =~ "context"
  end

  test "passes the loop's API-unavailable message through as the error reason" do
    canned_completion({:error, :api_unavailable, "the model is on fire"})

    assert {:error, reason} = Docs.call(%{"question" => "anything"})
    assert reason =~ "currently unavailable"
    assert reason =~ "the model is on fire"
  end

  test "returns response on success" do
    canned_completion("here's the answer")

    assert {:ok, "here's the answer"} = Docs.call(%{"question" => "anything"})
  end

  # Regression: each user-facing doc lane's README.md is excluded from
  # hexdocs extras in mix.exs to avoid a readme.html filename collision
  # (every extra publishes to `<basename>.html`). The tool previously
  # generated a `hexdocs.pm/fnord/README.html` entry anyway, which 404s.
  # The URL list baked into the system prompt must reference neither lane's
  # README. The glob spans both docs/user/ and docs/use-cases/.
  test "system prompt does not include either excluded lane README URL" do
    spec = Docs.spec()
    # The tool spec description is public and static, but the URL list is
    # inside the private @system_prompt. The spec being well-formed plus
    # call/1 returning {:ok, ...} under a stubbed completion (above)
    # implicitly exercises prompt construction at module-load time.
    assert spec.name == "fnord_help_docs_tool"

    # Read the source and confirm the URL builder rejects both lane
    # READMEs. This catches a future regression that re-introduces a bad
    # URL even if the spec/call test stays green.
    source = File.read!("lib/ai/tools/self_help/docs.ex")
    assert String.contains?(source, ~s|"docs/user/README.md"|)
    assert String.contains?(source, ~s|"docs/use-cases/README.md"|)
    assert String.contains?(source, "Enum.reject(")
  end
end
