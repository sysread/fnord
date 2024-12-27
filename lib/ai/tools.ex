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
  @callback call(agent :: struct, args :: map) :: {:ok, String.t()}

  @tools %{
    "file_contents_tool" => AI.Tools.FileContents,
    "file_info_tool" => AI.Tools.FileInfo,
    "git_diff_branch_tool" => AI.Tools.GitDiffBranch,
    "git_log_tool" => AI.Tools.GitLog,
    "git_pickaxe_tool" => AI.Tools.GitPickaxe,
    "git_show_tool" => AI.Tools.GitShow,
    "list_files_tool" => AI.Tools.ListFiles,
    "outline_tool" => AI.Tools.Outline,
    "save_strategy_tool" => AI.Tools.SaveStrategy,
    "search_strategies_tool" => AI.Tools.SearchStrategies,
    "search_tool" => AI.Tools.Search,
    "spelunker_tool" => AI.Tools.Spelunker
  }

  def perform_tool_call(state, tool, args) do
    case Map.get(@tools, tool) do
      nil -> {:error, :unknown_tool, tool}
      module -> module.call(state, args)
    end
  end
end
