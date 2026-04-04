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
            :parameters => map()
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
  @type json_parse_error :: {:error, Exception.t()}

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
  Returns a message to be displayed when a tool call fails. May return
  :default, :ignore, a binary message, or a {label, detail} tuple.
  """
  @callback tool_call_failure_message(args :: map, reason :: any) ::
              :default
              | :ignore
              | binary
              | {binary, binary}

  @doc """
  Returns the OpenAPI spec for the tool as an elixir map.
  """
  @callback spec() :: map()

  @doc """
  Calls the tool with the provided arguments and returns the response as an :ok
  tuple.
  """
  @callback call(args :: map) :: raw_tool_result

  # ----------------------------------------------------------------------------
  # General Tool Registry - only required for tools that are generally available
  # ----------------------------------------------------------------------------
  @tools %{
    "file_contents_tool" => AI.Tools.File.Contents,
    "file_info_tool" => AI.Tools.File.Info,
    "file_list_tool" => AI.Tools.File.List,
    "file_notes_tool" => AI.Tools.File.Notes,
    "file_reindex_tool" => AI.Tools.File.Reindex,
    "file_search_tool" => AI.Tools.File.Search,
    "file_spelunker_tool" => AI.Tools.File.Spelunker,
    "list_projects_tool" => AI.Tools.ListProjects,
    "notify_tool" => AI.Tools.Notify,
    "prior_research" => AI.Tools.Notes,
    "research_tool" => AI.Tools.Research,
    "cmd_tool" => AI.Tools.Cmd,
    "conversation_tool" => AI.Tools.Conversation,
    "memory_tool" => AI.Tools.Memory,
    "fnord_help_cli_tool" => AI.Tools.SelfHelp.Cli,
    "fnord_help_docs_tool" => AI.Tools.SelfHelp.Docs
  }

  @rw_tools %{
    "apply_patch" => AI.Tools.ApplyPatch,
    "file_contents_tool" => AI.Tools.File.Contents,
    "file_edit_tool" => AI.Tools.File.Edit,
    "notify_tool" => AI.Tools.Notify,
    "cmd_tool" => AI.Tools.Cmd
  }

  @worktree_tools %{
    "git_worktree_tool" => AI.Tools.Git.Worktree
  }

  @web_tools %{
    "web_search_tool" => AI.Tools.WebSearch
  }

  @ui_tools %{
    "ui_ask_tool" => AI.Tools.UI.Ask,
    "ui_choose_tool" => AI.Tools.UI.Choose,
    "ui_confirm_tool" => AI.Tools.UI.Confirm
  }

  @coding_tools %{
    "coder_tool" => AI.Tools.Coder
  }

  @review_tools %{
    "reviewer_tool" => AI.Tools.Reviewer
  }

  @task_tools %{
    "tasks_create_list" => AI.Tools.Tasks.CreateList,
    "tasks_add_task" => AI.Tools.Tasks.AddTask,
    "tasks_push_task" => AI.Tools.Tasks.PushTask,
    "tasks_resolve_task" => AI.Tools.Tasks.ResolveTask,
    "tasks_show_list" => AI.Tools.Tasks.ShowList
  }

  @skills_tools %{
    "run_skill" => AI.Tools.RunSkill,
    "save_skill" => AI.Tools.SaveSkill
  }

  # ----------------------------------------------------------------------------
  # API Functions
  # ----------------------------------------------------------------------------
  def tools, do: @tools

  @doc """
  Returns a `toolbox` that includes all tools (basic, read/write, coding, task,
  and web tools).

  WARNING: `all_tools/0` includes mutational tools (file edits, shell commands,
  coding tools). For normal runs, prefer `basic_tools/0` with selective
  `with_*` merges. Reserve `all_tools/0` for cases requiring full lookup
  fidelity (e.g., replay, diagnostics).
  """
  @spec all_tools() :: toolbox
  def all_tools() do
    basic_tools()
    |> with_mcps()
    |> with_frobs()
    |> with_ui()
    |> with_rw_tools()
    |> with_coding_tools()
    |> with_review_tools()
    |> with_task_tools()
    |> with_web_tools()
  end

  @doc """
  Returns a `toolbox` that includes all generally available tools and frobs.
  """
  @spec basic_tools() :: toolbox
  def basic_tools() do
    @tools
    |> Enum.filter(fn {_name, mod} -> mod.is_available?() end)
    |> Map.new()
  end

  @doc """
  Returns the allowed tool tags for skills. Skills.Runtime uses this to avoid duplicating the list.
  """
  @spec skill_tool_tags() :: [String.t()]
  def skill_tool_tags() do
    ["basic", "mcp", "frobs", "task", "coding", "web", "ui", "rw", "skills"]
  end

  @doc """
  Returns the deterministic skill tool tags order, excluding "basic", used when applying tags.
  """
  @spec stable_skill_tool_tag_order() :: [String.t()]
  def stable_skill_tool_tag_order() do
    ["mcp", "frobs", "task", "coding", "web", "ui", "rw", "skills"]
  end

  @doc """
  Adds MCP (Model Context Protocol) tools to the toolbox. MCP tools are
  externally hosted tool servers enabled at the project or global level.
  Starts the MCP service lazily on first call.
  """
  @spec with_mcps(toolbox) :: toolbox
  def with_mcps(toolbox \\ %{}) do
    Services.MCP.start()

    toolbox
    |> Map.merge(MCP.Tools.module_map())
  end

  @doc """
  Adds user-defined frobs to the toolbox. Frobs are local tooling (linters,
  formatters, test runners, kubectl wrappers, etc.) so they should only be
  given to agents that test, validate, or investigate - not to agents that
  only produce structured output (e.g. the Patcher).
  """
  @spec with_frobs(toolbox) :: toolbox
  def with_frobs(toolbox \\ %{}) do
    toolbox
    |> Map.merge(Frobs.module_map())
  end

  @doc """
  Adds the skills tools to the toolbox. Skills are specialized tools that
  should only be included when explicitly requested.
  """
  @spec with_skills(toolbox :: toolbox) :: toolbox
  def with_skills(toolbox \\ %{}) do
    toolbox
    |> Map.merge(@skills_tools)
    |> Enum.filter(fn {_name, mod} -> mod.is_available?() end)
    |> Map.new()
  end

  @doc """
  Adds the task management tools to the toolbox. This includes tools that can
  create and manage task lists.
  """
  @spec with_task_tools(toolbox :: toolbox) :: toolbox
  def with_task_tools(toolbox \\ %{}) do
    toolbox
    |> Map.merge(@task_tools)
  end

  @doc """
  Adds the web tools to the toolbox. This includes tools that can access the
  web, such as web search.
  """
  @spec with_web_tools(toolbox :: toolbox) :: toolbox
  def with_web_tools(toolbox \\ %{}) do
    toolbox
    |> Map.merge(@web_tools)
  end

  @doc """
  Adds interactive UI tools to the toolbox.

  These tools are intended for user-in-the-loop flows where the agent needs to
  ask the user a question and proceed based on the answer.
  """
  @spec with_ui(toolbox :: toolbox) :: toolbox
  def with_ui(toolbox \\ %{}) do
    toolbox
    |> Map.merge(@ui_tools)
    |> Enum.filter(fn {_name, mod} -> mod.is_available?() end)
    |> Map.new()
  end

  @doc """
  Conditionally adds UI tools to the toolbox if the current environment
  supports it (i.e., if we're running in a TTY and not in quiet mode).
  """
  @spec maybe_with_ui(AI.Tools.toolbox()) :: AI.Tools.toolbox()
  def maybe_with_ui(toolbox) do
    cond do
      !UI.is_tty?() -> toolbox
      UI.quiet?() -> toolbox
      true -> with_ui(toolbox)
    end
  end

  @doc """
  Adds the read/write tools to the toolbox. This includes tools that can
  **directly** perform file edits, shell commands, and other read/write
  operations.
  """
  @spec with_rw_tools(toolbox :: toolbox) :: toolbox
  def with_rw_tools(toolbox \\ %{}) do
    toolbox
    |> Map.merge(@rw_tools)
  end

  @doc """
  Adds the worktree tool to the toolbox when worktree actions are enabled.
  """
  @spec with_worktree_tool(toolbox :: toolbox, boolean) :: toolbox
  def with_worktree_tool(toolbox \\ %{}, enabled)

  def with_worktree_tool(toolbox, true) do
    toolbox
    |> Map.merge(@worktree_tools)
    |> Enum.filter(fn {_name, mod} -> mod.is_available?() end)
    |> Map.new()
  end

  def with_worktree_tool(toolbox, false), do: toolbox

  @doc """
  Adds the coding tools to the toolbox. Coding tools mutate the codebase, but
  do so in an organized, planned way, rather than directly managing files.
  """
  @spec with_coding_tools(toolbox :: toolbox) :: toolbox
  def with_coding_tools(toolbox \\ %{}) do
    toolbox
    |> Map.merge(@coding_tools)
  end

  @doc """
  Adds the review tools to the toolbox. Review tools are read-only agents that
  perform multi-specialist code review.
  """
  @spec with_review_tools(toolbox :: toolbox) :: toolbox
  def with_review_tools(toolbox \\ %{}) do
    toolbox
    |> Map.merge(@review_tools)
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
        basic_tools() |> with_mcps()
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
         {:ok, args} <- AI.Tools.Params.validate_json_args(module.spec(), args) do
      if Util.Env.looks_truthy?("FNORD_DEBUG_TOOLS") do
        UI.debug("Performing tool call", """
        # #{tool}
        #{inspect(args, pretty: true)}
        """)
      end

      try do
        # Call the tool's function with the provided arguments
        args
        |> module.call()
        # Convert results (or error) to a string for output
        |> case do
          # Binary responses
          {:ok, response} when is_binary(response) ->
            {:ok, response}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          # Structured responses
          {:ok, response} ->
            SafeJson.encode(response)

          {:error, reason} ->
            {:error, inspect(reason, pretty: true)}

          # Empty responses
          :ok ->
            {:ok, "#{tool} completed successfully"}

          :error ->
            {:error, "#{tool} failed with an unknown error"}

          # Frob errors
          {:error, code, msg} ->
            {:error, "#{tool} failed with code #{code}: #{msg}"}

          # Others
          otherwise ->
            {:error,
             "Unexpected result from tool <#{tool}>:\n#{inspect(otherwise, pretty: true)}"}
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
  def on_tool_request(tool, args, tools \\ nil)
  # Replay-specific clause: when the toolbox explicitly marks replay, skip

  # full argument validation and only render the UI note. This avoids noisy
  # validation/debug logging when replaying previously-recorded conversations.
  def on_tool_request(tool, args, %{"__replay__" => true} = tools) do
    case tool_module(tool, tools) do
      {:ok, module} ->
        try do
          module.ui_note_on_request(args)
        rescue
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # General clause: strict validation path used for live tool requests.
  def on_tool_request(tool, args, tools) do
    with {:ok, module} <- tool_module(tool, tools),
         {:ok, args} <- module.read_args(args),
         {:ok, args} <- AI.Tools.Params.validate_json_args(module.spec(), args) do
      try do
        module.ui_note_on_request(args)
      rescue
        e ->
          UI.debug(
            "Error logging tool call request",
            """
            # #{tool}
            #{inspect(args, pretty: true)}

            # Error
            #{Exception.format(:error, e, __STACKTRACE__)}
            """
          )

          nil
      end
    else
      {:error, :missing_argument, key} ->
        UI.debug("[tools]", "missing arg to tool #{tool}: #{key}")
        nil

      {:error, :invalid_argument, key} ->
        UI.debug("[tools]", "invalid arg to tool #{tool}: #{key}")
        nil

      {:error, :unknown_tool, tool} ->
        UI.debug("[tools]", "unknown tool: #{tool}")
        nil

      error ->
        UI.debug(
          "Error logging tool call request",
          """
          # #{tool}
          #{inspect(args, pretty: true)}

          # Error
          #{inspect(error, pretty: true)}
          """
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
            "Error logging tool call result",
            """
            # #{tool}
            #{inspect(args, pretty: true)}

            # Result
            #{inspect(result, pretty: true)}

            # Error
            #{Exception.format(:error, e, __STACKTRACE__)}
            """
          }

          nil
      end
    end
  end

  @spec on_tool_error(tool_name, parsed_args, any, toolbox | nil) ::
          :default
          | :ignore
          | binary
          | {binary, binary}
  def on_tool_error(tool, args, reason, tools \\ nil) do
    with {:ok, module} <- tool_module(tool, tools) do
      try do
        module.tool_call_failure_message(args, reason)
      rescue
        _ -> :default
      end
    else
      _ -> :default
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
          UI.debug(
            "AI.Tools.with_args/3 error",
            """
            # #{tool}
            #{inspect(args, pretty: true)}

            # Error
            #{Exception.format(:error, e, __STACKTRACE__)}
            """
          )

          {:error, :invalid_argument, e.message}

        e ->
          UI.debug(
            "AI.Tools.with_args/3 error",
            """
            # #{tool}
            #{inspect(args, pretty: true)}

            # Error
            #{Exception.format(:error, e, __STACKTRACE__)}
            """
          )

          {:error, "An unexpected error occurred:\n#{inspect(e)}"}
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

  @spec display_path(binary) :: binary
  @doc """
  Returns a file path relative to the current source root for display purposes.
  Falls back to the original path if it can't be relativized.
  """
  def display_path(path) when is_binary(path) do
    case Store.get_project() do
      {:ok, project} when is_binary(project.source_root) ->
        Path.relative_to(path, project.source_root)

      _ ->
        path
    end
  end

  @spec require_worktree_if_git() :: :ok | {:error, String.t()}
  @doc """
  Gate for write operations in git repositories. In a git repo, edits must
  target a worktree (either fnord-managed or user-supplied via `-W`). Returns
  `:ok` if not a git repo or if a project root override is set, otherwise
  returns an error instructing the LLM to create a worktree first.
  """
  def require_worktree_if_git do
    if GitCli.is_git_repo?() and is_nil(Settings.get_project_root_override()) do
      {:error,
       "This project is a git repository. All file edits must target a worktree " <>
         "to protect the main checkout. Use git_worktree_tool with action " <>
         "\"create\" to create a worktree before making changes."}
    else
      :ok
    end
  end

  @spec get_file_contents(binary) :: {:ok, binary} | something_not_found
  def get_file_contents(file) do
    if temp_file?(file) do
      # Tool output offloaded to a temp file (via maybe_offload_tool_output or
      # spill_tool_output_if_needed). These live outside the project root but
      # are our own files, so we read them directly without the root check.
      File.read(file)
      |> case do
        {:ok, _} = ok -> ok
        {:error, _} -> {:error, :enoent}
      end
    else
      with {:ok, project} <- get_project(),
           {:ok, path} <- Util.find_file_within_root(file, project.source_root),
           {:ok, contents} <- Services.FileCache.get_or_fetch(path, fn -> File.read(path) end) do
        {:ok, contents}
      else
        {:error, :enoent} -> {:error, :enoent}
        {:error, :project_not_found} = err -> err
        {:error, :project_not_set} = err -> err
        _ -> {:error, :enoent}
      end
    end
  end

  # Returns true if the path is under the system temp directory. This allows
  # file_contents_tool to read offloaded tool outputs that live outside the
  # project root.
  defp temp_file?(path) when is_binary(path) do
    case System.tmp_dir() do
      nil -> false
      tmp_dir -> Util.path_within_root?(Path.expand(path), Path.expand(tmp_dir))
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
end
