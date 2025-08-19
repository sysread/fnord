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
    def async?(), do: true

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
          :type => binary,
          :function => %{
            :name => binary,
            :description => binary,
            optional(:strict) => boolean,
            :parameters => %{
              optional(:additionalProperties) => boolean,
              :type => binary,
              :required => [binary],
              :properties => %{
                binary => %{
                  :type => binary,
                  :description => binary,
                  optional(:default) => any
                }
              }
            }
          }
        }

  @type tool_name :: binary
  @type project_name :: binary | nil
  @type unparsed_args :: binary
  @type parsed_args :: %{binary => any} | %{atom => any}
  @type toolbox :: %{binary => module}

  @type tool_error :: {:error, binary}
  @type unknown_tool_error :: {:error, :unknown_tool, binary}
  @type missing_arg_error :: {:error, :missing_argument, binary}
  @type invalid_arg_error :: {:error, :invalid_argument, binary}
  @type args_error :: missing_arg_error | invalid_arg_error
  @type frob_error :: {:error, non_neg_integer, binary}
  @type json_parse_error :: {:error, Jason.DecodeError.t()}

  @type tool_result ::
          {:ok, binary}
          | unknown_tool_error
          | args_error
          | tool_error
          | frob_error

  @type raw_tool_result ::
          :ok
          | {:ok, any}
          | {:error, any}
          | :error
          | args_error
          | frob_error

  @doc """
  Returns true if the tool is asynchronous, false otherwise. If `false`, when
  the LLM performs a multi-tool call, this tool will be called synchronously,
  after all other (asynchronous) tools have been called.
  """
  @callback async?() :: boolean

  @doc """
  Returns true if the tool is available for use, false otherwise. This is used
  to determine whether the tool can be used in the current context, such as
  whether the tool is available in the current project or if it requires
  specific conditions to be met (e.g., a project being set, availability of an
  external tool like ripgrep, etc.).
  """
  @callback is_available?() :: boolean

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
              {binary, binary}
              | binary
              | nil

  @doc """
  Return either a short string or a string tuple of label + detail to be
  displayed when the tool call is successful.
  """
  @callback ui_note_on_result(args :: map, result :: any) ::
              {binary, binary}
              | binary
              | nil

  @doc """
  Returns the OpenAPI spec for the tool as an elixir map.
  """
  @callback spec() :: tool_spec

  @doc """
  Calls the tool with the provided arguments and returns the response as an :ok
  tuple.
  """
  @callback call(args :: map) :: raw_tool_result

  # ----------------------------------------------------------------------------
  # General Tool Registry - only required for tools that are generally available
  # ----------------------------------------------------------------------------
  @tools %{
    "confirm_tool" => AI.Tools.Confirm,
    "file_contents_tool" => AI.Tools.File.Contents,
    "file_info_tool" => AI.Tools.File.Info,
    "file_list_tool" => AI.Tools.File.List,
    "file_notes_tool" => AI.Tools.File.Notes,
    "file_reindex_tool" => AI.Tools.File.Reindex,
    "file_search_tool" => AI.Tools.File.Search,
    "file_spelunker_tool" => AI.Tools.File.Spelunker,
    "git_diff_branch_tool" => AI.Tools.Git.DiffBranch,
    "git_grep_tool" => AI.Tools.Git.Grep,
    "git_list_branches_tool" => AI.Tools.Git.ListBranches,
    "git_log_tool" => AI.Tools.Git.Log,
    "git_pickaxe_tool" => AI.Tools.Git.Pickaxe,
    "git_show_tool" => AI.Tools.Git.Show,
    "git_unstaged_changes_tool" => AI.Tools.Git.UnstagedChanges,
    "list_projects_tool" => AI.Tools.ListProjects,
    "notify_tool" => AI.Tools.Notify,
    "prior_research" => AI.Tools.Notes,
    "research_tool" => AI.Tools.Research,
    "ripgrep_search" => AI.Tools.Ripgrep,
    "troubleshooter_tool" => AI.Tools.Troubleshooter
  }

  @rw_tools %{
    "file_edit_tool" => AI.Tools.File.Edit,
    "file_manage_tool" => AI.Tools.File.Manage,
    "shell_tool" => AI.Tools.Shell
  }

  @coding_tools %{
    "coder_tool" => AI.Tools.Coder,
    "shell_tool" => AI.Tools.Shell
  }

  # ----------------------------------------------------------------------------
  # API Functions
  # ----------------------------------------------------------------------------
  def tools, do: @tools

  @doc """
  Returns a `toolbox` that includes all generally available tools and frobs.
  """
  @spec all_tools() :: toolbox
  def all_tools() do
    @tools
    |> Map.merge(Frobs.module_map())
    |> Enum.filter(fn {_name, mod} -> mod.is_available?() end)
    |> Map.new()
  end

  @doc """
  Adds the read/write tools to the toolbox. This includes tools that can
  **directly** perform file edits, shell commands, and other read/write
  operations.
  """
  def with_rw_tools(toolbox) do
    toolbox
    |> Map.merge(@rw_tools)
  end

  @doc """
  Adds the coding tools to the toolbox. Coding tools mutate the codebase, but
  do so in an organized, planned way, rather than directly managing files.
  """
  def with_coding_tools(toolbox) do
    toolbox
    |> Map.merge(@coding_tools)
  end

  @doc """
  Generate a list of tool specs from a toolbox map.
  """
  @spec toolbox_to_specs(toolbox) :: [tool_spec]
  def toolbox_to_specs(toolbox), do: Enum.map(Map.values(toolbox), & &1.spec())

  @spec tool_module(tool_name, toolbox | nil) ::
          {:ok, module}
          | unknown_tool_error
  def tool_module(tool_name, tools \\ nil) do
    tools =
      if is_nil(tools) do
        all_tools()
      else
        tools
      end

    case Map.get(tools, tool_name) do
      nil -> {:error, :unknown_tool, tool_name}
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
          | {:error, :unknown_tool, binary}
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
      if System.get_env("FNORD_DEBUG_TOOLS") do
        UI.debug("Performing tool call for <#{tool}> with args: #{inspect(args)}")
      end

      try do
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
          # Frob errors
          {:error, code, msg} -> {:error, "#{tool} failed with code #{code}: #{msg}"}
          # Others
          otherwise -> {:error, "Unexpected result from tool <#{tool}>: #{inspect(otherwise)}"}
        end
      rescue
        e ->
          formatted = Exception.format(:error, e, __STACKTRACE__)

          {:error,
           """
           The tool `#{tool}` failed with an uncaught exception.
           This is likely a bug in the application, not in how the LLM invoked the tool.

           Please report this error to the developers of `fnord`:

           #{formatted}
           """}
      end
    end
  end

  @spec on_tool_request(tool_name, parsed_args, toolbox | nil) ::
          {binary, binary}
          | binary
          | nil
  def on_tool_request(tool, args, tools \\ nil) do
    with {:ok, module} <- tool_module(tool, tools),
         :ok <- validate_required_args(tool, args, tools),
         {:ok, processed_args} <- module.read_args(args) do
      try do
        module.ui_note_on_request(processed_args)
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
          {binary, binary}
          | binary
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

  @spec required_arg_error(binary) :: missing_arg_error
  def required_arg_error(key) do
    {:error, :missing_argument, key}
  end

  @spec with_args(tool_name, parsed_args, (parsed_args -> any), toolbox | nil) :: any
  def with_args(tool, args, fun, tools \\ nil) do
    with {:ok, module} <- tool_module(tool, tools),
         {:ok, args} <- module.read_args(args) do
      try do
        fun.(args)
      rescue
        e in ArgumentError ->
          UI.error(
            "AI.Tools.with_args/3 failed for <#{tool}> with args: #{inspect(args)}",
            Exception.format(:error, e, __STACKTRACE__)
          )

          {:error, :invalid_argument, e.message}

        e ->
          UI.error(
            "AI.Tools.with_args/3 failed for <#{tool}> with args: #{inspect(args)}",
            Exception.format(:error, e, __STACKTRACE__)
          )

          {:error, "An unexpected error occurred: #{inspect(e)}"}
      end
    end
  end

  @spec is_async?(tool_name, toolbox | nil) :: boolean
  def is_async?(tool_name, tools \\ nil) do
    with {:ok, module} <- tool_module(tool_name, tools) do
      module.async?()
    else
      _ -> false
    end
  end

  # ----------------------------------------------------------------------------
  # Common Utility Functions
  # ----------------------------------------------------------------------------
  @type project :: Store.Project.t()
  @type entry :: Store.Project.Entry.t()
  @type project_not_found :: {:error, :project_not_found} | {:error, :project_not_set}
  @type entry_not_found :: {:error, :enoent}
  @type something_not_found :: project_not_found | entry_not_found

  @doc """
  Retrieves an argument from the parsed arguments map. Empty strings or `nil`
  values will return an error indicating a missing argument.
  """
  @spec get_arg(parsed_args, atom | binary) :: {:ok, any} | missing_arg_error
  def get_arg(opts, key) do
    opts
    |> Map.fetch(key)
    |> case do
      {:ok, nil} -> {:error, :missing_argument, key}
      {:ok, value} -> {:ok, value}
      :error -> {:error, :missing_argument, key}
    end
  end

  @spec has_indexed_project() :: boolean
  def has_indexed_project do
    with {:ok, project} <- Store.get_project() do
      project |> Store.Project.has_index?()
    else
      _ -> false
    end
  end

  @spec get_project() :: {:ok, project} | project_not_found
  def get_project() do
    with {:ok, project} <- Store.get_project() do
      if Store.Project.exists_in_store?(project) do
        {:ok, project}
      else
        {:error, :project_not_found}
      end
    end
  end

  @spec get_entry(binary) :: {:ok, entry} | something_not_found
  def get_entry(file) do
    with {:ok, project} <- get_project() do
      get_entry(project, file)
    end
  end

  @spec get_entry(Store.Project.t(), binary) :: {:ok, entry} | entry_not_found
  def get_entry(project, file) do
    Store.Project.find_entry(project, file)
  end

  @spec get_file_contents(binary) :: {:ok, binary} | something_not_found
  def get_file_contents(file) do
    with {:ok, project} <- get_project(),
         {:ok, path} <- Util.find_file_within_root(file, project.source_root) do
      File.read(path)
    end
  end

  @doc """
  Given a list of modules, returns a map from tool_name => module, using each
  module's spec().function.name value as the key.
  """
  @spec build_toolbox([module] | %{binary => module} | nil) :: toolbox
  def build_toolbox(modules) when is_list(modules) do
    Enum.reduce(modules, %{}, fn mod, acc ->
      spec = mod.spec()

      fun_name =
        case spec[:function] do
          nil -> spec["function"]
          val -> val
        end

      name = fun_name[:name] || fun_name["name"]

      if is_binary(name) and name != "" do
        Map.put(acc, name, mod)
      else
        acc
      end
    end)
  end

  def build_toolbox(modules) when is_map(modules), do: modules
  def build_toolbox(nil), do: %{}

  # ----------------------------------------------------------------------------
  # Private Functions
  # ----------------------------------------------------------------------------
  defp check_required_args([], _args) do
    :ok
  end

  defp check_required_args([key | keys], args) do
    with :ok <- get_required_arg(args, key) do
      check_required_args(keys, args)
    end
  end

  defp get_required_arg(args, key) do
    args
    |> Map.fetch(key)
    |> case do
      :error -> required_arg_error(key)
      {:ok, nil} -> required_arg_error(key)
      _ -> :ok
    end
  end
end
