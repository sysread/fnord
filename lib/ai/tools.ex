defmodule AI.Tools do
  @moduledoc """
  This module defines the behaviour for tool calls. Defining a new tool
  requires implementing the `spec/0` and `call/2` functions.

  The `spec/0` function should return a map that describes the tool's
  capabilities and arguments, using a map to represent the OpenAPI spec.

  The `call/2` function generates the tool call response. It accepts the
  requesting `AI.Completion`'s struct and a map derived from the parsed JSON
  provided by the agent, containing the tool call arguments. Note that, because
  the arguments are parsed from JSON, the keys will all be strings. Whether
  those are converted to symbols is between the tool implementation and the
  code it calls. What happens behind closed APIs is none of MY business.

  ## Skeleton Implementation
  ```elixir
  defmodule AI.Tools.MyNewTool do
    @behaviour AI.Tools

    @impl AI.Tools
    def ui_note_on_request(_args) do
      {"Doing something", "This tool is doing something."}
    end

    @impl AI.Tools
    def ui_note_on_result(_args, _result) do
      {"Did something", "This tool did something."}
    end

    @impl AI.Tools
    def read_args(args) do
      {:ok, args}
    end

    @impl AI.Tools
    def spec() do
      %{
        type: "function",
        function: %{
          name: "something_tool",
          description: "This tool does something.",
          strict: true,
          parameters: %{
            additionalProperties: false,
            type: "object",
            required: ["thing"],
            properties: %{
              thing: %{
                type: "string",
                description: "The thing to do."
              }
            }
          }
        }
      }
    end

    @impl AI.Tools
    def call(_completion, args) do
      {:ok, "IMPLEMENT ME"}
    end
  end
  ```
  """

  @type args_error ::
          {:error, :missing_argument, String.t()}
          | {:error, :invalid_argument, String.t()}

  @doc """
  Returns the OpenAPI spec for the tool as an elixir map.
  """
  @callback spec() :: map

  @doc """
  Calls the tool with the provided arguments and returns the response as an :ok
  tuple.
  """
  @callback call(completion :: AI.Completion.t(), args :: map) ::
              :ok
              | {:ok, any}
              | {:error, any}
              | :error

  @doc """
  Reads the arguments and returns a map of the arguments if they are valid.
  This is used to validate args before the tool is called. The result is what
  is passed to `call/2`, `ui_note_on_request/1`, and `ui_note_on_result/2`.
  """
  @callback read_args(args :: map) :: {:ok, map} | args_error

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

  # ----------------------------------------------------------------------------
  # Tool Registry
  # ----------------------------------------------------------------------------
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
    "git_grep_tool" => AI.Tools.Git.Grep,
    "git_list_branches_tool" => AI.Tools.Git.ListBranches,
    "git_log_tool" => AI.Tools.Git.Log,
    "git_pickaxe_tool" => AI.Tools.Git.Pickaxe,
    "git_show_tool" => AI.Tools.Git.Show
  }

  @notes_tools %{
    "notes_save_tool" => AI.Tools.Notes.Save
  }

  @tools %{}
         |> Map.merge(@file_tools)
         |> Map.merge(@git_tools)
         |> Map.merge(@notes_tools)

  # ----------------------------------------------------------------------------
  # API Functions
  # ----------------------------------------------------------------------------
  def tools, do: @tools

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
         {:ok, args} <- module.read_args(args),
         :ok <- validate_required_args(tool, args, tools) do
      module.call(state, args)
    end
  end

  def on_tool_request(tool, args, tools \\ @tools) do
    with {:ok, module} <- tool_module(tool, tools),
         {:ok, args} <- module.read_args(args),
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
    with {:ok, module} <- tool_module(tool, tools),
         {:ok, args} <- module.read_args(args) do
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

  def required_arg_error(key) do
    {:error, :missing_argument, key}
  end

  def with_args(tool, args, fun) do
    with {:ok, module} <- tool_module(tool),
         {:ok, args} <- module.read_args(args) do
      fun.(args)
    end
  end

  # ----------------------------------------------------------------------------
  # Common Utility Functions
  # ----------------------------------------------------------------------------
  def get_project() do
    project = Store.get_project()

    if Store.Project.exists_in_store?(project) do
      {:ok, project}
    else
      {:error, :project_not_found}
    end
  end

  def get_file_contents(file) do
    with {:ok, project} <- get_project() do
      get_file_contents(project, file)
    end
  end

  def get_file_contents(project, file) do
    case get_entry(project, file) do
      {:ok, entry} -> Store.Project.Entry.read_source_file(entry)
      {:error, :not_found} -> {:error, :enoent}
    end
  end

  def get_entry(file) do
    with {:ok, project} <- get_project() do
      get_entry(project, file)
    end
  end

  def get_entry(project, file) do
    Store.Project.find_entry(project, file)
  end

  # ----------------------------------------------------------------------------
  # Private Functions
  # ----------------------------------------------------------------------------
  defp check_required_args([], _args) do
    :ok
  end

  defp check_required_args([key | keys], args) do
    with :ok <- get_arg(args, key) do
      check_required_args(keys, args)
    else
      _ -> required_arg_error(key)
    end
  end

  defp get_arg(args, key) do
    args
    |> Map.fetch(key)
    |> case do
      :error -> required_arg_error(key)
      {:ok, ""} -> required_arg_error(key)
      {:ok, nil} -> required_arg_error(key)
      _ -> :ok
    end
  end
end
