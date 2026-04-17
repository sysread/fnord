defmodule ExternalConfigs.Injector do
  @moduledoc """
  Runtime injection of Cursor auto-attached rules triggered by a file path
  that the model has read or written.

  This is the moving part that mirrors Cursor's own "auto-attach" semantics:
  when a file is added to the chat context, any rule whose globs match that
  file should be in context too. In fnord we interpret "added to context" as
  "read by file_contents_tool" or "written by file_edit_tool".

  Each rule-path pair fires at most once per session (gated via
  `Services.Once`). Injected messages are system-role and are stripped from
  the persisted conversation, just like the other coordinator scaffolding.
  """

  alias ExternalConfigs.CursorRule

  @doc """
  Consider injecting auto-attached rules matching the given file path. Safe
  to call in any context; returns `:ok` silently when no project is
  selected, external-configs are disabled, Once is not running, or no rule
  matches.
  """
  @spec maybe_inject_for_path(String.t()) :: :ok
  def maybe_inject_for_path(file_path) when is_binary(file_path) do
    with true <- once_running?(),
         {:ok, pid} <- active_conversation_pid(),
         {:ok, project} <- Store.get_project(),
         true <- Settings.ExternalConfigs.enabled?(project.name, :cursor_rules) do
      rel = relative_path(project, file_path)

      matches =
        project
        |> ExternalConfigs.Loader.load_cursor_rules()
        |> Enum.filter(&(&1.mode == :auto_attached))
        |> Enum.filter(&CursorRule.matches_path?(&1, rel))

      debug_log_checked(rel, matches)

      Enum.each(matches, fn rule -> inject_once(rule, rel, pid) end)

      :ok
    else
      _ -> :ok
    end
  end

  defp inject_once(%CursorRule{} = rule, rel, pid) do
    # Key composition: rule.path scopes the gate per rule file so a
    # different rule with the same name doesn't re-use a prior rule's
    # slot; rel scopes it per triggering file so each distinct matched
    # path earns its own injection. That gives the LLM a fresh (rule,
    # file) pair every time it encounters a new file. The rule body is
    # the same, but the cited path binds the rule to the file that just
    # entered context.
    key = {:external_configs_cursor_rule_auto_attached, rule.path, rel}

    result =
      Services.Once.run(key, fn ->
        msg =
          rule
          |> ExternalConfigs.Catalog.render_auto_attached_rule(rel)
          |> AI.Util.system_msg()

        Services.Conversation.append_msg(msg, pid)
      end)

    case result do
      :ignore -> debug_log_skipped(rule, rel)
      _ -> debug_log_injected(rule, rel)
    end

    result
  end

  defp active_conversation_pid() do
    case Services.Globals.get_env(:fnord, :current_conversation, nil) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  # Load-bearing guard: file tools are exercised by tests that don't boot
  # the full Services supervision tree, so Services.Once may not be
  # registered. Calling Services.Once.run/2 in that state would crash the
  # tool call. Early-exit keeps the injector a no-op outside live
  # sessions.
  defp once_running?() do
    case Process.whereis(Services.Once) do
      nil -> false
      _ -> true
    end
  end

  defp relative_path(%Store.Project{source_root: nil}, path), do: path

  defp relative_path(%Store.Project{source_root: root}, path) do
    path
    |> Path.expand(root)
    |> Path.relative_to(root)
  end

  # ----------------------------------------------------------------------------
  # Debug logging (gated by FNORD_DEBUG_CURSOR_RULES)
  # ----------------------------------------------------------------------------
  defp debug_log_checked(rel, matches) do
    if Util.Env.cursor_rules_debug_enabled?() do
      case matches do
        [] ->
          UI.debug(
            "cursor_rules",
            format_kv("no auto-attached rules matched", file: rel)
          )

        _ ->
          UI.debug(
            "cursor_rules",
            format_kv("auto-attached rules matched file",
              file: rel,
              count: length(matches),
              rules: Enum.map(matches, & &1.name)
            )
          )
      end
    end
  end

  defp debug_log_injected(%CursorRule{} = rule, rel) do
    if Util.Env.cursor_rules_debug_enabled?() do
      UI.debug(
        "cursor_rules",
        format_kv("injected auto-attached rule",
          rule: rule.name,
          file: rel,
          globs: Enum.join(rule.globs, ", ")
        )
      )
    end
  end

  defp debug_log_skipped(%CursorRule{} = rule, rel) do
    if Util.Env.cursor_rules_debug_enabled?() do
      UI.debug(
        "cursor_rules",
        format_kv("skipped auto-attached rule (already injected this session)",
          rule: rule.name,
          file: rel
        )
      )
    end
  end

  # Render a keyword list as a multi-line markdown list. List-valued entries
  # nest a second level of bullets for readability.
  defp format_kv(header, pairs) do
    lines =
      Enum.map(pairs, fn
        {k, values} when is_list(values) ->
          nested = Enum.map_join(values, "\n", fn v -> "  - #{v}" end)
          "- #{k}:\n#{nested}"

        {k, v} ->
          "- #{k}: #{v}"
      end)

    Enum.join([header | lines], "\n")
  end
end
