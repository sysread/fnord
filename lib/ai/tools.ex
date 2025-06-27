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
    def call(args) do
      {:ok, "IMPLEMENT ME"}
    end
  end
  ```
  """

  @type tool_spec :: %{
          :type => String.t(),
          :function => %{
            :name => String.t(),
            :description => String.t(),
            optional(:strict) => boolean,
            :parameters => %{
              optional(:additionalProperties) => boolean,
              :type => String.t(),
              :required => [String.t()],
              :properties => %{
                String.t() => %{
                  :type => String.t(),
                  :description => String.t(),
                  optional(:default) => any
                }
              }
            }
          }
        }

  @type tool_name :: String.t()
  @type project_name :: String.t() | nil
  @type unparsed_args :: String.t()
  @type parsed_args :: %{String.t() => any}
  @type toolbox :: %{String.t() => module}

  @type tool_error :: {:error, String.t()}
  @type unknown_tool_error :: {:error, :unknown_tool, String.t()}
  @type missing_arg_error :: {:error, :missing_argument, String.t()}
  @type invalid_arg_error :: {:error, :invalid_argument, String.t()}
  @type args_error :: missing_arg_error | invalid_arg_error
  @type frob_error :: {:error, non_neg_integer, String.t()}

  @type tool_result ::
          {:ok, String.t()}
          | unknown_tool_error
          | args_error
          | tool_error
          | frob_error

  @type raw_tool_result ::
          :ok
          | {:ok, any}
          | {:error, any}
          | :error
          | frob_error

  @doc """
  Returns the OpenAPI spec for the tool as an elixir map.
  """
  @callback spec() :: tool_spec

  @doc """
  Calls the tool with the provided arguments and returns the response as an :ok
  tuple.
  """
  @callback call(args :: map) :: raw_tool_result

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
  # General tools for researching the project.
  @general_tools %{
    "file_contents_tool" => AI.Tools.File.Contents,
    "file_info_tool" => AI.Tools.File.Info,
    "file_list_tool" => AI.Tools.File.List,
    "file_outline_tool" => AI.Tools.File.Outline,
    "file_search_tool" => AI.Tools.File.Search,
    "file_spelunker_tool" => AI.Tools.File.Spelunker,
    "research_tool" => AI.Tools.Research,
    "ripgrep_search" => AI.Tools.Ripgrep
  }

  # Tools for interacting with git repositories.
  @git_tools %{
    "git_diff_branch_tool" => AI.Tools.Git.DiffBranch,
    "git_grep_tool" => AI.Tools.Git.Grep,
    "git_list_branches_tool" => AI.Tools.Git.ListBranches,
    "git_log_tool" => AI.Tools.Git.Log,
    "git_pickaxe_tool" => AI.Tools.Git.Pickaxe,
    "git_show_tool" => AI.Tools.Git.Show,
    "git_unstaged_changes_tool" => AI.Tools.Git.UnstagedChanges
  }

  # Tools that are intended for AI.Agent.Default.
  @default_tools %{
    "prompt" => AI.Tools.Default.Prompt,
    "notes" => AI.Tools.Default.Notes
  }

  # Tools that can mutate state (editing files, making commits, etc.)
  @rw_tools %{
    "file_edit_tool" => AI.Tools.File.Edit
  }

  @tools %{}
         |> Map.merge(@general_tools)
         |> Map.merge(@git_tools)
         |> Map.merge(@default_tools)
         |> Map.merge(@rw_tools)

  # ----------------------------------------------------------------------------
  # API Functions
  # ----------------------------------------------------------------------------
  def tools, do: @tools

  @spec all_tools(project_name) :: toolbox
  def all_tools(project_name \\ nil) do
    Map.merge(@tools, Frobs.module_map(project_name))
  end

  @spec all_tool_specs_for_project(project_name) :: [tool_spec]
  def all_tool_specs_for_project(project_name \\ nil) do
    tools =
      @general_tools
      |> Map.keys()
      |> Enum.map(&AI.Tools.tool_spec!(&1, @tools))

    search_available? = AI.Tools.File.Search.is_available?()
    ripgrep_available? = AI.Tools.Ripgrep.is_available?()

    if !search_available? and !ripgrep_available? do
      UI.fatal("No search tools available. Please index your project, install ripgrep, or both.")
    end

    # If the selected project has an index, add the file search tool.
    tools =
      if search_available? do
        tools ++ [AI.Tools.tool_spec!("file_search_tool")]
      else
        UI.warn("project is not indexed; semantic search unavailable")
        tools
      end

    # If ripgrep is available, add the ripgrep search tool.
    tools =
      if ripgrep_available? do
        unless search_available? do
          UI.warn("falling back on ripgrep for file search")
        end

        tools ++ [AI.Tools.tool_spec!("ripgrep_search")]
      else
        UI.warn("ripgrep not found in PATH; file search unavailable")
        tools
      end

    tools =
      if Git.is_git_repo?() do
        tools ++
          (@git_tools
           |> Map.keys()
           |> Enum.map(&AI.Tools.tool_spec!(&1, @tools)))
      else
        tools
      end

    frobs =
      project_name
      |> Frobs.module_map()
      |> Enum.map(fn {_name, module} ->
        module.spec()
      end)

    tools ++ frobs
  end

  @spec tool_module(tool_name, toolbox | nil) ::
          {:ok, module}
          | unknown_tool_error
  def tool_module(tool, tools \\ nil) do
    tools = if is_nil(tools), do: all_tools(), else: tools

    case Map.get(tools, tool) do
      nil -> {:error, :unknown_tool, tool}
      module -> {:ok, module}
    end
  end

  @spec tool_spec!(tool_name, toolbox | nil) :: tool_spec
  def tool_spec!(tool, tools \\ nil) do
    with {:ok, module} <- tool_module(tool, tools) do
      module.spec()
    else
      {:error, :unknown_tool, tool} ->
        raise ArgumentError, "Unknown tool: #{tool}"
    end
  end

  @spec tool_spec(tool_name, toolbox | nil) ::
          {:ok, tool_spec}
          | {:error, :unknown_tool, String.t()}
  def tool_spec(tool, tools \\ nil) do
    with {:ok, module} <- tool_module(tool, tools) do
      {:ok, module.spec()}
    end
  end

  @spec perform_tool_call(tool_name, parsed_args, toolbox | nil) :: tool_result
  def perform_tool_call(tool, args, tools \\ nil) do
    with {:ok, module} <- tool_module(tool, tools),
         {:ok, args} <- module.read_args(args),
         :ok <- validate_required_args(tool, args, tools) do
      # Call the tool's function with the provided arguments
      args
      |> module.call()
      # Convert results (or error) to a string for output
      |> case do
        # Binary responses
        {:ok, response} when is_binary(response) -> {:ok, response}
        {:error, reason} when is_binary(reason) -> {:error, reason}
        # Structured responses
        {:ok, response} -> Jason.encode(response)
        {:error, reason} -> {:error, inspect(reason)}
        # Empty responses
        :ok -> {:ok, "#{tool} completed successfully"}
        :error -> {:error, "#{tool} failed with an unknown error"}
      end
    end
  end

  @spec on_tool_request(tool_name, parsed_args, toolbox | nil) ::
          {String.t(), String.t()}
          | String.t()
          | nil
  def on_tool_request(tool, args, tools \\ nil) do
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

  @spec on_tool_result(tool_name, parsed_args, any, toolbox | nil) ::
          {String.t(), String.t()}
          | String.t()
          | nil
  def on_tool_result(tool, args, result, tools \\ nil) do
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

  @spec validate_required_args(tool_name, parsed_args, toolbox | nil) :: :ok | args_error
  def validate_required_args(tool, args, tools \\ nil) do
    with {:ok, module} <- tool_module(tool, tools) do
      module.spec()
      |> Map.get(:function)
      |> Map.get(:parameters)
      |> Map.get(:required)
      |> check_required_args(args)
    end
  end

  @spec required_arg_error(String.t()) :: missing_arg_error
  def required_arg_error(key) do
    {:error, :missing_argument, key}
  end

  @spec with_args(tool_name, parsed_args, (parsed_args -> any), toolbox | nil) :: any
  def with_args(tool, args, fun, tools \\ nil) do
    with {:ok, module} <- tool_module(tool, tools),
         {:ok, args} <- module.read_args(args) do
      fun.(args)
    end
  end

  # ----------------------------------------------------------------------------
  # Common Utility Functions
  # ----------------------------------------------------------------------------
  @type project :: Store.Project.t()
  @type entry :: Store.Project.Entry.t()
  @type project_not_found :: {:error, :project_not_found}
  @type entry_not_found :: {:error, :enoent}
  @type something_not_found :: project_not_found | entry_not_found

  @spec get_project() :: {:ok, project} | project_not_found
  def get_project() do
    project = Store.get_project()

    if Store.Project.exists_in_store?(project) do
      {:ok, project}
    else
      {:error, :project_not_found}
    end
  end

  @spec get_entry(String.t()) :: {:ok, entry} | something_not_found
  def get_entry(file) do
    with {:ok, project} <- get_project() do
      get_entry(project, file)
    end
  end

  @spec get_entry(Store.Project.t(), String.t()) :: {:ok, entry} | entry_not_found
  def get_entry(project, file) do
    Store.Project.find_entry(project, file)
  end

  @spec get_file_contents(String.t()) :: {:ok, String.t()} | something_not_found
  def get_file_contents(file) do
    with {:ok, project} <- get_project(),
         {:ok, path} <- Util.find_file_within_root(file, project.source_root) do
      File.read(path)
    end
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
