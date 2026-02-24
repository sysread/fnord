defmodule Memory.Migration do
  @moduledoc """
  Helpers for repairing and migrating memory index statuses.

  This module provides programmatic functions (not a mix task) so migration
  can be invoked in an escript environment or in tests. The default behavior
  is a dry-run listing of candidate memories; pass `apply?: true` to perform
  an in-place repair (set index_status to :analyzed).
  """

  @doc """
  Scan global and project memories and optionally set nil index_status to :analyzed.

  Usage:
    Memory.Migration.migrate_nil_statuses(project \\ nil, apply?: false)

  When `project` is nil the current selected project is used (via Store.get_project()).
  Returns {:ok, report_map} where report_map contains lists of affected memories.
  """
  def migrate_nil_statuses(project \\ nil, opts \\ []) do
    apply? = Keyword.get(opts, :apply?, false)

    # Global
    {:ok, global_titles} = Memory.Global.list()

    global_candidates =
      global_titles
      |> Enum.filter(fn title ->
        case Memory.read(:global, title) do
          {:ok, mem} -> is_nil(mem.index_status)
          _ -> false
        end
      end)
      |> Enum.map(fn title -> {:global, title} end)

    # Project
    project_candidates =
      case Store.get_project(project) do
        {:ok, _proj} ->
          {:ok, project_titles} = Memory.Project.list()

          project_titles
          |> Enum.filter(fn title ->
            case Memory.read(:project, title) do
              {:ok, mem} -> is_nil(mem.index_status)
              _ -> false
            end
          end)
          |> Enum.map(fn title -> {:project, title} end)

        _ ->
          []
      end

    # Session memories: scan conversation files for session memories with nil status
    session_candidates =
      case Store.get_project(project) do
        {:ok, proj} ->
          Store.Project.Conversation.list(proj)
          |> Enum.flat_map(fn conv ->
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
          end)

        _ ->
          []
      end

    report = %{
      global: global_candidates,
      project: project_candidates,
      session: session_candidates
    }

    if apply? do
      Enum.each(global_candidates, fn {:global, title} ->
        Memory.set_status(:global, title, :analyzed)
      end)

      Enum.each(project_candidates, fn {:project, title} ->
        Memory.set_status(:project, title, :analyzed)
      end)

      # For session candidates, update the conversation files
      case Store.get_project(project) do
        {:ok, proj} ->
          Store.Project.Conversation.list(proj)
          |> Enum.each(fn conv ->
            case Store.Project.Conversation.read(conv) do
              {:ok, data} ->
                updated_mem =
                  data.memory
                  |> Enum.map(fn
                    %Memory{scope: :session, index_status: nil} = m ->
                      %{m | index_status: :analyzed}

                    other ->
                      other
                  end)

                data = Map.put(data, :memory, updated_mem)
                Store.Project.Conversation.write(conv, data)

              _ ->
                :ok
            end
          end)

        _ ->
          :ok
      end

      {:ok, Map.put(report, :applied, true)}
    else
      {:ok, Map.put(report, :applied, false)}
    end
  end
end
