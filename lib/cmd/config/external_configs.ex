defmodule Cmd.Config.ExternalConfigs do
  @moduledoc """
  CLI surface for toggling per-project support for Cursor rules, Cursor
  skills, Claude Code skills, and Claude Code subagents. The underlying
  persistence lives in `Settings.ExternalConfigs`; this module is the
  user-facing entry point.

  Four sources are supported: `cursor:rules`, `cursor:skills`,
  `claude:skills`, `claude:agents`. All default to disabled; enabling any
  source opts the selected project into discovery of the matching files
  from both the user's home directory and the project source root.
  """

  @doc """
  Dispatches `fnord config external-configs` subcommands.
  """
  @spec run(map(), list(), list()) :: :ok
  def run(opts, command, args)

  def run(opts, [:external_configs, :list], _args) do
    with {:ok, project_name} <- resolve_project(opts),
         :ok <- ensure_project_exists(project_name) do
      project_name
      |> Settings.ExternalConfigs.flags()
      |> format_flags()
      |> SafeJson.encode!(pretty: true)
      |> UI.puts()
    else
      {:error, :project_not_set} ->
        UI.error("Project not specified or not found")

      {:error, :project_not_found} ->
        UI.error("Project not found")
    end
  end

  def run(opts, [:external_configs, :enable], args), do: toggle(opts, args, true)
  def run(opts, [:external_configs, :disable], args), do: toggle(opts, args, false)

  # Matches the precondition that Settings.ExternalConfigs.set/3 enforces
  # for enable/disable. Without this, `list --project does-not-exist`
  # silently returns the all-false defaults and the user has no way to
  # tell they typed the wrong name.
  defp ensure_project_exists(project_name) do
    case Settings.get_project_data(Settings.new(), project_name) do
      nil -> {:error, :project_not_found}
      _ -> :ok
    end
  end

  defp toggle(opts, args, value) do
    with {:ok, project_name} <- resolve_project(opts),
         {:ok, raw_source} <- Cmd.Config.Utils.require_key(opts, args, :source, "Source"),
         {:ok, source} <- Settings.ExternalConfigs.source_from_string(raw_source),
         {:ok, flags} <- Settings.ExternalConfigs.set(project_name, source, value) do
      flags
      |> format_flags()
      |> SafeJson.encode!(pretty: true)
      |> UI.puts()
    else
      {:error, :project_not_set} ->
        UI.error("Project not specified or not found")

      {:error, :project_not_found} ->
        UI.error("Project not found")

      {:error, {:invalid_source, raw}} ->
        UI.error(
          "Invalid source: #{inspect(raw)}. Valid sources: #{Enum.join(Settings.ExternalConfigs.source_strings(), ", ")}"
        )

      {:error, message} when is_binary(message) ->
        UI.error(message)
    end
  end

  @spec resolve_project(map()) :: {:ok, String.t()} | {:error, :project_not_set}
  defp resolve_project(%{project: project_name}) when is_binary(project_name) do
    Settings.set_project(project_name)
    {:ok, project_name}
  end

  defp resolve_project(opts) when is_map(opts) do
    Settings.get_selected_project()
  end

  @spec format_flags(Settings.ExternalConfigs.flags()) :: map()
  defp format_flags(flags) do
    Map.new(flags, fn {k, v} -> {Settings.ExternalConfigs.source_to_string(k), v} end)
  end
end
