defmodule AI.Tools.Shell do
  @default_timeout_ms 30_000
  @max_timeout_ms 300_000

  @runner """
  #!/bin/sh
  set -euf
  tmp="$1"; shift
  exec "$@" < "$tmp"
  """

  # ----------------------------------------------------------------------------
  # Behaviour implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args) do
    case validate_commands(args) do
      :ok ->
        with {:ok, op} <- AI.Tools.get_arg(args, "operator"),
             true <- op in ["|", "&&"] do
          {:ok, args}
        else
          {:error, :missing_argument, _} ->
            {:error, :invalid_argument, "missing required field 'operator'"}

          false ->
            {:error, :invalid_argument, "operator must be '|' or '&&'"}
        end

      {:error, reason} ->
        {:error, :invalid_argument, reason}
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{"commands" => commands, "description" => desc} = args) do
    op = Map.fetch!(args, "operator")
    command = format_commands(op, commands)
    {"shell> #{command}", desc}
  end

  def ui_note_on_request(other) do
    {"shell", "Invalid JSON args: #{inspect(other)}"}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"commands" => commands} = args, result) do
    op = Map.fetch!(args, "operator")
    command = format_commands(op, commands)
    {"shell> #{command}", result}
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, _error_message), do: :default

  @impl AI.Tools
  def spec do
    {os_family, os_name} = :os.type()

    allowed =
      Services.Approvals.Shell.preapproved_cmds()
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    user_prefixes =
      Services.Approvals.Shell.list_user_prefixes()
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")
      |> case do
        "" -> "(none)"
        s -> s
      end

    user_regexes =
      Services.Approvals.Shell.list_user_regexes()
      |> Enum.map(&"- /#{&1}/")
      |> Enum.join("\n")
      |> case do
        "" -> "(none)"
        s -> s
      end

    %{
      type: "function",
      function: %{
        name: "shell_tool",
        description: """
        Executes a series of shell commands, and returns the mixed STDOUT and STDERR output.

        When to use this tool:

        - Use shell_tool for filesystem-level operations involving one or more files or directories, such as:
          - deleting files or directories (e.g., `rm`, `rm -r`),
          - moving or renaming files or directories (e.g., `mv`, `git mv`),
          - creating directories (e.g., `mkdir -p`),
          - applying bulk or multi-file changes using standard CLI tools.
        - Use shell_tool to run project tools and commands that the user would normally run from the terminal, such as:
          - `go test`, `mix format`, `mix dialyzer`, `npm test`, etc.
          - `git status`, `git diff`, `git apply`, etc.
        - Use shell_tool to create temporary files or directories as needed for testing, verification, or other operations.

        When a specialized tool exists for the exact operation (for example, file_edit_tool for small, in-file edits), prefer that specialized tool first.
        Otherwise, shell_tool is appropriate for filesystem-level and multi-file operations.

        If you are unsure of whether a command is available, try calling it with --version or --help.
        You can do this for multiple commands with concurrent tool calls to this tool.

        The user must approve execution of this command before it is run.
        It is essential to remember that you cannot launch interactive commands!
        Commands that require user input or interaction will fail after a timeout, resulting in a poor experience for the user.

        INDIVIDUAL COMMANDS SHOULD BE SIMPLE:
          - Do not include redirection (`>`, `<`), pipes (`|`, `&&`), command substitution (`$()`, backticks), semicolons (`;`), or other complex shell syntax inside a single command's "command" or "args".
          - Pipelines are supported by supplying multiple command objects and setting "operator" to "|".

        Example:

        {
          "operator": "|",
          "commands": [
            { "command": "ls", "args": ["-l"] },
            { "command": "grep", "args": ["foo"] }
          ]
        }

        IMPORTANT: Tools that can modify files (e.g., `awk`, `find -exec`, `patch`) require explicit user-approval.
        Safe, read-only `sed` invocations (without `-i`, `-f`, `e` or `w` ops) are auto-preapproved by built-in regex rules.

        IMPORTANT: This uses elixir's System.cmd/3 to execute commands.
                   It *will* `cd` into the project's source root before executing commands.
                   Some commands DO behave differently without a tty.
                   For example, `rg` REQUIRES a path argument when not run in a tty.

        For commands that vary based on OS (like grep and sed), the current OS is: #{os_name} (#{os_family}).
        Note that the user may not be monitoring the terminal to see your command request, so pay careful attention to which commands are pre-approved.

        The following tools are available on your PATH with their respective versions:
        #{available_tools()}

        The following commands are preapproved and will execute without requiring user approval:
        #{allowed}

        User-configured preapprovals (command + subcommands):
        #{user_prefixes}

        User-configured preapprovals (full-command regex):
        #{user_regexes}

        Examples:

        1) Delete a single file:

        {
          "description": "Delete obsolete module file",
          "operator": "&&",
          "commands": [
            { "command": "rm", "args": ["lib/my_app/obsolete.ex"] }
          ]
        }

        2) Move/rename a file with git:

        {
          "description": "Move legacy module into new namespace",
          "operator": "&&",
          "commands": [
            { "command": "git", "args": ["mv", "lib/my_app/legacy.ex", "lib/my_app/new/legacy.ex"] }
          ]
        }
        """,
        parameters: %{
          type: "object",
          required: ["description", "commands", "operator"],
          additionalProperties: false,
          properties: %{
            description: %{
              type: "string",
              description: """
              Explain to the user what the command does and why it is needed.
              This will be displayed to the user in the approval dialog.
              """
            },
            timeout_ms: %{
              type: "integer",
              description: """
              Optional execution timeout in milliseconds.
              Defaults to #{@default_timeout_ms}.
              Must be > 0 and ≤ #{@max_timeout_ms}.
              """
            },
            operator: %{
              type: "string",
              enum: ["|", "&&"],
              description: """
              Specifies whether commands are piped together (`|`) or
              run sequentially (`&&`). This field is required.
              """
            },
            commands: %{
              type: "array",
              description: """
              A list of commands to execute either piped together or run in
              sequence, depending on the value of the `operator` argument.

              Example:

              - Equivalent to `ls -l -a -h | grep some_pattern`:
              ```json
              [
                {"command": "ls", "args": ["-l", "-a", "-h"]},
                {"command": "grep", "args": ["some_pattern"]}
              ]
              ```
              """,
              items: %{
                type: "object",
                description: "An individual command within the overall pipeline.",
                required: ["command", "args"],
                additionalProperties: false,
                properties: %{
                  command: %{
                    type: "string",
                    description: "The base command to execute, without any arguments or options."
                  },
                  args: %{
                    type: "array",
                    description: """
                    A list of arguments and options to pass to the command.
                    This does NOT include the command itself.
                    """,
                    items: %{
                      type: "string",
                      description: """
                      An individual argument or option for the command.
                      This value does not require any special escaping.
                      The code executing it will handle proper shell escaping.
                      Environmental variables (e.g. `$HOME`) will NOT be expanded.
                      """
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(opts) do
    with {:ok, desc} <- AI.Tools.get_arg(opts, "description"),
         {:ok, commands} <- AI.Tools.get_arg(opts, "commands"),
         timeout_ms <- sanitize_timeout(opts),
         {:ok, commands} <- resolve_commands(commands),
         {:ok, project} <- Store.get_project() do
      opts
      |> Map.get("operator", "&&")
      |> route(commands, desc, timeout_ms, project.source_root)
    end
  end

  # ----------------------------------------------------------------------------
  # Validation and argument processing
  # ----------------------------------------------------------------------------

  # ----------------------------------------------------------------------------
  # Sanitize timeout to be a positive integer within allowed range
  # ----------------------------------------------------------------------------
  defp sanitize_timeout(opts) do
    val = Map.get(opts, "timeout_ms", @default_timeout_ms)

    cond do
      !is_integer(val) -> @default_timeout_ms
      val <= 0 -> @default_timeout_ms
      val > @max_timeout_ms -> @max_timeout_ms
      true -> val
    end
  end

  # ----------------------------------------------------------------------------
  # Resolve commands to absolute paths where possible.
  # ----------------------------------------------------------------------------
  defp resolve_commands(commands) do
    commands
    |> Enum.reduce_while([], fn command, acc ->
      command
      |> find_executable()
      |> case do
        {:ok, resolved_cmd} -> {:cont, [resolved_cmd | acc]}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
    |> case do
      {:error, msg} -> {:error, msg}
      resolved_commands -> {:ok, Enum.reverse(resolved_commands)}
    end
  end

  # ----------------------------------------------------------------------------
  # Command resolution
  # ----------------------------------------------------------------------------
  defp find_executable(command) when is_binary(command) do
    cond do
      String.starts_with?(command, "/") -> Path.expand(command)
      String.starts_with?(command, "~") -> Path.expand(command)
      true -> command
    end
    |> System.find_executable()
    |> case do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  # -----------------------------------------------------------------------------
  # LLMs *love* `rg`, but they often forget to provide a path argument, even
  # when it's explicitly called out in the tool spec. This special case adds
  # the project's source_root as a path argument if no other path-like
  # arguments are provided. If the LLM provides a pattern arg that *looks* like
  # a path, and no other path-like args, we can't do anything sensible, since
  # we don't know *which* arg they borked, so we just let the command fail.
  # -----------------------------------------------------------------------------
  defp find_executable(%{"command" => "rg", "args" => args})
       when is_list(args) do
    with {:ok, path} <- find_executable("rg") do
      args
      # Filter out options, leaving only positional args
      |> Enum.filter(fn arg -> not String.starts_with?(arg, "-") end)
      # See if any of the positional args look like a path (contain a dot or slash)
      |> Enum.filter(fn arg -> String.starts_with?(arg, ".") or String.starts_with?(arg, "/") end)
      # If no positional args look like a path, add the project's source_root to search current dir
      |> case do
        # None found.
        [] ->
          with {:ok, project} <- Store.get_project() do
            {:ok, %{"command" => path, "args" => args ++ [project.source_root]}}
          else
            # This shouldn't be possible, but if it does happen, just return as-is
            _ -> {:ok, %{"command" => path, "args" => args}}
          end

        _ ->
          {:ok, %{"command" => path, "args" => args}}
      end
    end
  end

  defp find_executable(%{"command" => command, "args" => args} = cmd)
       when is_list(args) do
    if String.contains?(command, " ") do
      command
      |> find_executable()
      |> case do
        {:ok, cmd} ->
          {:ok, %{"command" => cmd, "args" => args}}

        # Try splitting on spaces and see if the first part is executable
        {:error, :not_found} ->
          [base | extra_args] = String.split(command, " ")
          find_executable(%{"command" => base, "args" => extra_args ++ args})
      end
    else
      command
      |> find_executable()
      |> case do
        {:ok, cmd} -> {:ok, %{"command" => cmd, "args" => args}}
        {:error, :not_found} -> {:error, "Command not found: #{format_command(cmd)}"}
      end
    end
  end

  defp find_executable(%{"command" => _} = cmd) do
    cmd
    |> Map.put("args", [])
    |> find_executable()
  end

  # -----------------------------------------------------------------------------
  # Execution and routing
  # -----------------------------------------------------------------------------

  # ----------------------------------------------------------------------------
  # The fact that this function exists at all is so, *so* frustrating.
  # ----------------------------------------------------------------------------
  defp route(op, commands, desc, timeout_ms, root) do
    commands
    |> Jason.encode(pretty: true)
    |> case do
      {:ok, json} ->
        # Ok, so we can fudge things this way, but the shell_tool is available
        # outside of edit mode, so we need to double-check that the user
        # actually wants to allow editing before we let them do it.
        is_apply_patch? =
          Enum.any?(commands, fn %{"command" => cmd, "args" => args} ->
            cond do
              cmd =~ ~r/\b(z|ba)?sh .*? <<<.*?\b(patch|apply_patch|git apply)\b/ ->
                true

              Path.basename(cmd) in ["bash", "sh", "zsh"] and
                  Enum.any?(args, fn a ->
                    String.contains?(a, "apply_patch") or String.contains?(a, "patch")
                  end) ->
                true

              Path.basename(cmd) in ["apply_patch", "patch"] ->
                true

              Path.basename(cmd) == "git" and "apply" in args ->
                true

              true ->
                false
            end
          end)

        is_edit_mode? = Settings.get_edit_mode()

        cond do
          is_edit_mode? and is_apply_patch? ->
            UI.info("Oof", "The LLM attempted to apply a patch with the shell_tool. Rerouting.")
            AI.Tools.ApplyPatch.call(%{"patch" => json})

          is_apply_patch? and not is_edit_mode? ->
            {:denied, "Cannot edit files; the user did not pass --edit."}

          true ->
            run_as_shell_commands(op, commands, desc, timeout_ms, root)
        end

      _ ->
        run_as_shell_commands(op, commands, desc, timeout_ms, root)
    end
  end

  defp run_as_shell_commands(_, [%{"command" => "echo", "args" => [msg]}], _, _, _) do
    AI.Tools.Notify.call(%{"level" => "info", "message" => msg})
    {:ok, {"#{msg}\n", 0}}
  end

  defp run_as_shell_commands(op, commands, desc, timeout_ms, root) do
    {op, commands, desc}
    |> Services.Approvals.confirm(:shell)
    |> case do
      {:ok, :approved} -> run_pipeline(op, commands, timeout_ms, root)
      other -> other
    end
  end

  # ----------------------------------------------------------------------------
  # Run the commands as a shell pipeline or sequence, collecting the output.
  # ----------------------------------------------------------------------------
  defp run_pipeline(op, commands, timeout_ms, root, acc \\ nil)
  defp run_pipeline(_, [], _, _, ""), do: {:ok, "(no output)"}
  defp run_pipeline(_, [], _, _, acc), do: {:ok, acc}

  defp run_pipeline(op, [command | rest], timeout_ms, root, acc) do
    input =
      case op do
        "|" -> acc
        "&&" -> nil
      end

    command
    |> shell_out(timeout_ms, root, input)
    |> case do
      {:error, :timeout} ->
        {:ok,
         """
         Command: #{format_command(command)}
         Error: timed out after #{timeout_ms} ms
         Remember that interactive commands will always time out.
         Some commands behave differently outside of an interactive shell.
         """}

      {:ok, {out, 0}} ->
        case op do
          "|" ->
            run_pipeline(op, rest, timeout_ms, root, out)

          "&&" ->
            acc = """
            #{acc}

            $ #{format_command(command)}
            #{out}
            """

            run_pipeline(op, rest, timeout_ms, root, acc)
        end

      # Some commands exit non-zero even when behaving as expected, like grep.
      # In this case, we still want to return the output, but in a true shell
      # pipeline, it would still stop processing the rest of the commands.
      {:ok, {out, code}} ->
        {:ok,
         """
         #{acc}

         -----
         Command: #{format_command(command)}
         Exit status: #{code}
         Output:
         #{out}
         """}
    end
  end

  defp shell_out(%{"command" => cmd, "args" => args}, timeout_ms, root, nil) do
    run_with_timeout(timeout_ms, fn ->
      {:ok, System.cmd(cmd, args, cd: root, stderr_to_stdout: true)}
    end)
  end

  defp shell_out(%{"command" => cmd, "args" => args}, timeout_ms, root, stdin) do
    Util.Temp.with_tmp(stdin, fn tmp ->
      # Ensure stdin temp file is not world/group readable regardless of umask
      with :ok <- File.chmod(tmp, 0o600),
           {:ok, runner} <- Briefly.create(),
           :ok <- File.write(runner, @runner),
           :ok <- File.chmod(runner, 0o700) do
        run_with_timeout(
          timeout_ms,
          fn ->
            try do
              {:ok, System.cmd(runner, [tmp, cmd | args], cd: root, stderr_to_stdout: true)}
            after
              # normal completion cleanup
              File.rm(tmp)
              File.rm(runner)
            end
          end,
          on_timeout: fn ->
            # timeout cleanup fallback
            File.rm(tmp)
            File.rm(runner)
          end
        )
      end
    end)
  end

  # ----------------------------------------------------------------------------
  # Runs a function with the specified `timeout`, returning `{:error,
  # :timeout}` if it times out.
  # ----------------------------------------------------------------------------
  defp run_with_timeout(timeout, fun, opts \\ []) do
    on_timeout = Keyword.get(opts, :on_timeout, fn -> :ok end)

    task =
      Services.Globals.Spawn.async(fn ->
        try do
          fun.()
        rescue
          e -> {:error, e}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        # task did not respond, was force-killed
        on_timeout.()
        {:error, :timeout}

      {:exit, _reason} ->
        on_timeout.()
        {:error, :timeout}
    end
  end

  # ----------------------------------------------------------------------------
  # Argument validation helpers
  # ----------------------------------------------------------------------------
  defp validate_commands(%{"commands" => commands}) when is_list(commands) do
    commands
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {cmd, idx}, _acc ->
      case validate_command(cmd, idx) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_commands(%{"commands" => commands}) do
    {:error, "commands must be a list, got: #{inspect(commands)}"}
  end

  defp validate_commands(_) do
    {:error, "missing required field 'commands'"}
  end

  defp validate_command(%{"command" => cmd, "args" => args}, idx)
       when is_binary(cmd) and is_list(args) do
    # Check that all args are strings
    case Enum.all?(args, &is_binary/1) do
      true -> :ok
      false -> {:error, "command[#{idx}].args must be a list of strings"}
    end
  end

  defp validate_command(%{"command" => cmd}, _idx) when is_binary(cmd) do
    # args is optional, can be missing
    :ok
  end

  defp validate_command(cmd, idx) do
    {:error,
     "command[#{idx}] invalid format: expected {command: string, args: [strings]}, got: #{inspect(cmd)}"}
  end

  # ----------------------------------------------------------------------------
  # Formatting helpers
  # ----------------------------------------------------------------------------
  defp format_commands(op, commands) do
    try do
      commands
      |> Enum.map(&format_command/1)
      |> Enum.join(" #{op} ")
    rescue
      _ -> "Invalid command list: #{inspect(commands, pretty: true)}"
    end
  end

  # Check if an argument needs quoting (non-flag arguments)
  defp needs_quoting?(arg) do
    # Only quote non-flag arguments that contain a space
    !String.starts_with?(arg, "-") && String.contains?(arg, " ")
  end

  # Escape and quote an argument for display
  defp quote_arg(arg) do
    # Escape backslashes and double quotes
    escaped =
      arg
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp format_command(%{"command" => command, "args" => args}) do
    formatted_args =
      Enum.map(args, fn arg ->
        if needs_quoting?(arg) do
          quote_arg(arg)
        else
          arg
        end
      end)

    [command | formatted_args]
    |> Enum.join(" ")
  end

  defp format_command(invalid_format) do
    "Invalid command format: #{inspect(invalid_format, pretty: true)}"
  end

  # ----------------------------------------------------------------------------
  # Available tools
  # ----------------------------------------------------------------------------
  @non_posix_tools_memo_table :shell_tools_cache

  @non_posix_tools [
    ["ack", "--version"],
    ["ag", "--version"],
    ["docker", "--version"],
    ["docker-compose", "--version"],
    ["expect", "-v"],
    ["fd", "--version"],
    ["fzf", "--version"],
    ["gh", "--version"],
    ["git", "--version"],
    ["helm", "--version"],
    ["kubectl", "version", "--client=true"],
    ["perl", "-e", "print \"$^V\\n\""],
    ["rg", "--version"]
  ]

  defp available_tools do
    # Create memoization table if it doesn't exist
    if :ets.info(@non_posix_tools_memo_table) == :undefined do
      :ets.new(@non_posix_tools_memo_table, [:named_table, :public, read_concurrency: true])
    end

    # Check if we have a cached value
    case :ets.lookup(@non_posix_tools_memo_table, :cached) do
      [{:cached, result}] ->
        result

      [] ->
        result =
          @non_posix_tools
          # Filter out tools that are not on our PATH
          |> Util.async_filter(fn [cmd | _] ->
            cmd
            |> System.find_executable()
            |> case do
              nil -> false
              _ -> true
            end
          end)
          # For each remaining tool, run the command to get its version
          |> Util.async_stream(fn [cmd | args] ->
            case System.cmd(cmd, args, stderr_to_stdout: true) do
              {out, 0} ->
                out
                |> String.split("\n")
                |> List.first()
                |> String.trim()
                |> then(&"- #{cmd}: #{&1}")

              _ ->
                "- #{cmd}: (unknown version)"
            end
          end)
          # Resolve async_stream results, ignoring any errors
          |> Enum.reduce([], fn
            {:ok, line}, acc -> [line | acc]
            {:error, _}, acc -> acc
          end)
          |> Enum.sort()
          |> Enum.join("\n")

        :ets.insert(@non_posix_tools_memo_table, {:cached, result})
        result
    end
  end
end
