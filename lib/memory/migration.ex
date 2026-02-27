defmodule Memory.Migration do
  @moduledoc """
  Helpers for repairing and migrating memory index statuses.

  This module provides programmatic functions (not a mix task) so migration
  can be invoked in an escript environment or in tests. The default behavior
  is a dry-run listing of candidate memories; pass `apply?: true` to perform
  an in-place repair (set index_status to :analyzed).
  """

  @doc """
  Scan global, project, and session memories for nil index_status.

  When `project` is nil, the current selected project is used (via
  Store.get_project()). Returns {:ok, report_map} where report_map
  contains lists of affected memories.
  """
  def migrate_nil_statuses(project \\ nil, opts \\ []) do
    apply? = Keyword.get(opts, :apply?, false)

    report = %{
      global: find_nil_status_memories(:global),
      project: find_nil_status_project_memories(project),
      session: find_nil_status_session_memories(project)
    }

    if apply? do
      apply_status_repairs(report, project)
      {:ok, Map.put(report, :applied, true)}
    else
      {:ok, Map.put(report, :applied, false)}
    end
  end

  # --------------------------------------------------------------------------
  # Scanning
  # --------------------------------------------------------------------------
  defp find_nil_status_memories(:global) do
    {:ok, titles} = Memory.Global.list()

    titles
    |> Enum.filter(&has_nil_status?(:global, &1))
    |> Enum.map(fn title -> {:global, title} end)
  end

  defp find_nil_status_project_memories(project) do
    case Store.get_project(project) do
      {:ok, _} ->
        {:ok, titles} = Memory.Project.list()

        titles
        |> Enum.filter(&has_nil_status?(:project, &1))
        |> Enum.map(fn title -> {:project, title} end)

      _ ->
        []
    end
  end

  defp find_nil_status_session_memories(project) do
    case Store.get_project(project) do
      {:ok, proj} ->
        proj
        |> Store.Project.Conversation.list()
        |> Enum.flat_map(&session_memories_with_nil_status/1)

      _ ->
        []
    end
  end

  defp has_nil_status?(scope, title) do
    case Memory.read(scope, title) do
      {:ok, mem} -> is_nil(mem.index_status)
      _ -> false
    end
  end

  defp session_memories_with_nil_status(conv) do
    case Store.Project.Conversation.read(conv) do
      {:ok, data} ->
        data.memory
        |> Enum.filter(fn
          %Memory{scope: :session, index_status: nil} -> true
          _ -> false
        end)
        |> Enum.map(fn m -> {conv.id, m.title} end)

      _ ->
        []
    end
  end

  # --------------------------------------------------------------------------
  # Applying repairs
  # --------------------------------------------------------------------------
  defp apply_status_repairs(report, project) do
    repair_scoped_memories(report.global)
    repair_scoped_memories(report.project)
    repair_session_memories(project)
  end

  defp repair_scoped_memories(candidates) do
    Enum.each(candidates, fn {scope, title} ->
      Memory.set_status(scope, title, :analyzed)
    end)
  end

  defp repair_session_memories(project) do
    case Store.get_project(project) do
      {:ok, proj} ->
        proj
        |> Store.Project.Conversation.list()
        |> Enum.each(&repair_conversation_session_memories/1)

      _ ->
        :ok
    end
  end

  defp repair_conversation_session_memories(conv) do
    case Store.Project.Conversation.read(conv) do
      {:ok, data} ->
        updated_mem =
          Enum.map(data.memory, fn
            %Memory{scope: :session, index_status: nil} = m ->
              %{m | index_status: :analyzed}

            other ->
              other
          end)

        data
        |> Map.put(:memory, updated_mem)
        |> then(&Store.Project.Conversation.write(conv, &1))

      _ ->
        :ok
    end
  end
end
