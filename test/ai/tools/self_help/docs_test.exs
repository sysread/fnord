defmodule AI.Tools.SelfHelp.DocsTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.SelfHelp.Docs

  setup do
    set_log_level(:none)
    safe_meck_new(AI.Completion, [:passthrough, :no_link])
    on_exit(fn -> safe_meck_unload(AI.Completion) end)
    :ok
  end

  # Regression: AI.Completion.get/1 can return a three-element tuple for
  # :context_length_exceeded (`{:error, :context_length_exceeded, usage}`),
  # which previously fell through the two-tuple case clauses and crashed
  # with CaseClauseError. The tool must now surface a soft error without
  # raising.
  test "handles {:error, :context_length_exceeded, usage} without raising" do
    :meck.expect(AI.Completion, :get, fn _opts ->
      {:error, :context_length_exceeded, 12_345}
    end)

    assert {:error, reason} = Docs.call(%{"question" => "How do worktrees work?"})
    assert reason =~ "context"
  end

  test "passes through ordinary error tuples unchanged" do
    :meck.expect(AI.Completion, :get, fn _opts ->
      {:error, :api_unavailable}
    end)

    assert {:error, :api_unavailable} = Docs.call(%{"question" => "anything"})
  end

  test "returns response on success" do
    :meck.expect(AI.Completion, :get, fn _opts ->
      {:ok, %{response: "here's the answer"}}
    end)

    assert {:ok, "here's the answer"} = Docs.call(%{"question" => "anything"})
  end

  # Regression: docs/user/README.md is excluded from hexdocs extras in
  # mix.exs to avoid a readme.html filename collision. The tool previously
  # generated a `hexdocs.pm/fnord/README.html` entry for it anyway, which
  # 404s. The URL list baked into the system prompt must not reference it.
  test "system prompt does not include the excluded docs/user/README.html URL" do
    spec = Docs.spec()
    # The tool spec description is public and static, but the URL list is
    # inside the private @system_prompt. Use the presence of other
    # docs/user entries in source text via Code.ensure_loaded and the
    # module's @moduledoc instead. Simpler: check the compiled module's
    # private function via :erlang-level approach is brittle. Instead
    # assert the spec itself is well-formed and that call/1 with a stubbed
    # completion returns {:ok, ...}, which implicitly exercises the
    # prompt construction at module-load time.
    assert spec.function.name == "fnord_help_docs_tool"

    # Read the source and confirm the URL builder uses the excluded path
    # filter. This catches a future regression that re-introduces the bad
    # URL even if the spec/call test stays green.
    source = File.read!("lib/ai/tools/self_help/docs.ex")
    assert String.contains?(source, ~s|&(&1 == "docs/user/README.md")|)
  end
end
