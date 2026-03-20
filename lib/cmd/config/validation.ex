defmodule Cmd.Config.Validation do
  @moduledoc """
  Manages project validation rules stored in validation settings.

  This module provides the config command integration points for listing,
  adding, removing, and clearing validation rules for the selected project.
  """

  @doc """
  Runs validation config commands for the selected project, including
  listing, adding, removing, and clearing validation rules.
  """
  @spec run(map(), list(), list()) :: :ok
  def run(opts, command, args)

  def run(opts, [:validation, :list], _args) do
    with {:ok, project_name} <- resolve_project(opts) do
      project_name
      |> Settings.Validation.list()
      |> format_rules()
      |> SafeJson.encode!(pretty: true)
      |> UI.puts()
    else
      {:error, :project_not_set} ->
        UI.error("Project not specified or not found")
    end
  end

  def run(opts, [:validation, :add], args) do
    with {:ok, project_name} <- resolve_project(opts),
         {:ok, command} <- Cmd.Config.Utils.require_key(opts, args, :command, "Command"),
         {:ok, path_globs} <- resolve_path_globs(opts),
         {:ok, rules} <- Settings.Validation.add_rule(project_name, command, path_globs) do
      rules
      |> format_rules()
      |> SafeJson.encode!(pretty: true)
      |> UI.puts()
    else
      {:error, :project_not_set} ->
        UI.error("Project not specified or not found")

      {:error, :invalid_rule} ->
        UI.error("Invalid validation rule")

      {:error, message} when is_binary(message) ->
        UI.error(message)
    end
  end

  def run(opts, [:validation, :remove], args) do
    with {:ok, project_name} <- resolve_project(opts),
         {:ok, index} <- parse_index(opts, args),
         {:ok, rules} <- Settings.Validation.remove_rule(project_name, index) do
      rules
      |> format_rules()
      |> SafeJson.encode!(pretty: true)
      |> UI.puts()
    else
      {:error, :project_not_set} ->
        UI.error("Project not specified or not found")

      {:error, :invalid_index} ->
        UI.error("Invalid validation rule index")

      {:error, message} when is_binary(message) ->
        UI.error(message)
    end
  end

  def run(opts, [:validation, :clear], _args) do
    with {:ok, project_name} <- resolve_project(opts),
         :ok <- Settings.Validation.clear(project_name) do
      project_name
      |> Settings.Validation.list()
      |> format_rules()
      |> SafeJson.encode!(pretty: true)
      |> UI.puts()
    else
      {:error, :project_not_set} ->
        UI.error("Project not specified or not found")

      {:error, :project_not_found} ->
        UI.error("Project not found")
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

  @spec resolve_path_globs(map()) :: {:ok, [String.t()]}
  defp resolve_path_globs(%{path_glob: path_glob}) when is_binary(path_glob) do
    {:ok, [path_glob]}
  end

  defp resolve_path_globs(%{path_glob: path_globs})
       when is_list(path_globs) and path_globs != [] do
    {:ok, path_globs}
  end

  defp resolve_path_globs(_opts) do
    {:ok, ["."]}
  end

  @spec parse_index(map(), list()) :: {:ok, integer()} | {:error, String.t()}
  defp parse_index(opts, args) do
    with {:ok, raw_index} <- Cmd.Config.Utils.require_key(opts, args, :index, "Index"),
         {index, ""} when index > 0 <- Integer.parse(raw_index) do
      {:ok, index}
    else
      {:error, message} -> {:error, message}
      _ -> {:error, "Invalid validation rule index"}
    end
  end

  @spec format_rules([Settings.Validation.rule()]) :: [map()]
  defp format_rules(rules) do
    rules
    |> Enum.with_index(1)
    |> Enum.map(fn {rule, index} ->
      %{
        "index" => index,
        "command" => rule.command,
        "path_globs" => rule.path_globs
      }
    end)
  end
end
