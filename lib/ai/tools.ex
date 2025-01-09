defmodule AI.Tools do
  @moduledoc """
  This module defines the behaviour for tool calls. Defining a new tool
  requires implementing the `spec/0` and `call/2` functions.

  The `spec/0` function should return a map that describes the tool's
  capabilities and arguments, using a map to represent the OpenAPI spec.

  The `call/2` function generates the tool call response. It accepts the
  requesting agent's struct and a map, derived from the parsed JSON provided by
  the agent, containing the tool call arguments. Note that, because the
  arguments are parsed from JSON, the keys will all be strings. Whether those
  are converted to symbols is between the tool implementation and the code it
  calls. What happens behind closed APIs is none of MY business.
  """

  @doc """
  Returns the OpenAPI spec for the tool as an elixir map.
  """
  @callback spec() :: map

  @doc """
  Calls the tool with the provided arguments and returns the response as an :ok
  tuple.
  """
  @callback call(agent :: struct, args :: map) ::
              :ok
              | {:ok, any}
              | {:error, any}
              | :error

  @doc """
  Return either a short string or a string tuple of label + detail to be
  displayed when the tool is called.
  """
  @callback ui_note_on_request(args :: map) ::
              {String.t(), String.t()}
              | String.t()
              | nil

  @doc """
  Return either a short string or a string tuple of label + detail to be
  displayed when the tool call is successful.
  """
  @callback ui_note_on_result(args :: map, result :: any) ::
              {String.t(), String.t()}
              | String.t()
              | nil

  @file_tools %{
    "file_contents_tool" => AI.Tools.File.Contents,
    "file_info_tool" => AI.Tools.File.Info,
    "file_list_tool" => AI.Tools.File.List,
    "file_outline_tool" => AI.Tools.File.Outline,
    "file_search_tool" => AI.Tools.File.Search,
    "file_spelunker_tool" => AI.Tools.File.Spelunker
  }

  @git_tools %{
    "git_diff_branch_tool" => AI.Tools.Git.DiffBranch,
    "git_log_tool" => AI.Tools.Git.Log,
    "git_pickaxe_tool" => AI.Tools.Git.Pickaxe,
    "git_show_tool" => AI.Tools.Git.Show
  }

  @notes_tools %{
    "notes_search_tool" => AI.Tools.Notes.Search,
    "notes_save_tool" => AI.Tools.Notes.Save
  }

  @strategies_tools %{
    "strategies_save_tool" => AI.Tools.Strategies.Save,
    "strategies_search_tool" => AI.Tools.Strategies.Search,
    "strategies_suggest_tool" => AI.Tools.Strategies.Suggest
  }

  @tools %{}
         |> Map.merge(@file_tools)
         |> Map.merge(@git_tools)
         |> Map.merge(@notes_tools)
         |> Map.merge(@strategies_tools)

  def tool_module(tool, tools \\ @tools) do
    case Map.get(tools, tool) do
      nil -> {:error, :unknown_tool, tool}
      module -> {:ok, module}
    end
  end

  def tool_spec!(tool, tools \\ @tools) do
    with {:ok, module} <- tool_module(tool, tools) do
      module.spec()
    else
      {:error, :unknown_tool, _tool} ->
        raise ArgumentError, "Unknown tool: #{tool}"
    end
  end

  def tool_spec(tool, tools \\ @tools) do
    with {:ok, module} <- tool_module(tool, tools) do
      {:ok, module.spec()}
    end
  end

  def perform_tool_call(state, tool, args, tools \\ @tools) do
    with {:ok, module} <- tool_module(tool, tools),
         :ok <- validate_required_args(tool, args, tools) do
      module.call(state, args)
    end
  end

  def on_tool_request(tool, args, tools \\ @tools) do
    with {:ok, module} <- tool_module(tool, tools),
         :ok <- validate_required_args(tool, args, tools) do
      try do
        module.ui_note_on_request(args)
      rescue
        e ->
          UI.error(
            "Error logging tool call request for <#{tool}> (args: #{inspect(args)})",
            inspect(e)
          )

          nil
      end
    else
      {:error, :missing_argument, _key} ->
        nil

      error ->
        UI.error(
          "Error logging tool call request for <#{tool}> (args: #{inspect(args)})",
          inspect(error)
        )

        nil
    end
  end

  def on_tool_result(tool, args, result, tools \\ @tools) do
    with {:ok, module} <- tool_module(tool, tools) do
      try do
        module.ui_note_on_result(args, result)
      rescue
        e in ArgumentError ->
          {
            "Error logging tool call result for <#{tool}> (args: #{inspect(args)})",
            inspect(e)
          }
      end
    end
  end

  def validate_required_args(tool, args, tools \\ @tools) do
    with {:ok, module} <- tool_module(tool, tools) do
      module.spec()
      |> Map.get(:function)
      |> Map.get(:parameters)
      |> Map.get(:required)
      |> check_required_args(args)
    end
  end

  defp check_required_args([], _args) do
    :ok
  end

  defp check_required_args([key | keys], args) do
    with :ok <- get_arg(args, key) do
      check_required_args(keys, args)
    else
      _ -> {:error, :missing_argument, key}
    end
  end

  defp get_arg(args, key) do
    args
    |> Map.fetch(key)
    |> case do
      :error -> {:error, :missing_argument, key}
      {:ok, ""} -> {:error, :missing_argument, key}
      {:ok, nil} -> {:error, :missing_argument, key}
      _ -> :ok
    end
  end
end
