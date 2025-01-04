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

  @tools %{
    "file_contents_tool" => AI.Tools.FileContents,
    "file_info_tool" => AI.Tools.FileInfo,
    "git_diff_branch_tool" => AI.Tools.GitDiffBranch,
    "git_log_tool" => AI.Tools.GitLog,
    "git_pickaxe_tool" => AI.Tools.GitPickaxe,
    "git_show_tool" => AI.Tools.GitShow,
    "list_files_tool" => AI.Tools.ListFiles,
    "outline_tool" => AI.Tools.Outline,
    "prior_research_tool" => AI.Tools.PriorResearch,
    "save_notes_tool" => AI.Tools.SaveNotes,
    "save_strategy_tool" => AI.Tools.SaveStrategy,
    "search_strategies_tool" => AI.Tools.SearchStrategies,
    "search_tool" => AI.Tools.Search,
    "spelunker_tool" => AI.Tools.Spelunker,
    "suggest_strategy_tool" => AI.Tools.SuggestStrategy
  }

  def tool_module(tool) do
    case Map.get(@tools, tool) do
      nil -> {:error, :unknown_tool, tool}
      module -> {:ok, module}
    end
  end

  def perform_tool_call(state, tool, args) do
    with {:ok, module} <- tool_module(tool) do
      module.call(state, args)
    end
  end

  def on_tool_request(tool, args) do
    with {:ok, module} <- tool_module(tool) do
      try do
        module.ui_note_on_request(args)
      rescue
        e in ArgumentError -> "Error logging tool call request: #{inspect(e)}"
      end
    end
  end

  def on_tool_result(tool, args, result) do
    with {:ok, module} <- tool_module(tool) do
      try do
        module.ui_note_on_result(args, result)
      rescue
        e in ArgumentError -> "Error logging tool call result: #{inspect(e)}"
      end
    end
  end
end
