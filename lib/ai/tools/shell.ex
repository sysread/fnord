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
        case Map.get(args, "operator") do
          nil ->
            {:ok, args}

          op when op in ["|", "&&"] ->
            {:ok, args}

          _ ->
            {:error, :invalid_argument, "operator must be '|' or '&&'"}
        end

      {:error, reason} ->
        {:error, :invalid_argument, reason}
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{"commands" => commands, "description" => desc} = args) do
    op = Map.get(args, "operator", "&&")
    timeout = sanitize_timeout(args)
    command = format_commands(op, commands)
    {"(timeout: #{div(timeout, 1000)}s) cmd> #{command}", desc}
  end

  def ui_note_on_request(other) do
    {"cmd", "Invalid JSON args: #{inspect(other)}"}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"commands" => commands} = args, result) do
    op = Map.get(args, "operator", "&&")
    command = format_commands(op, commands)
    {"cmd> #{command}", result}
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
        name: "cmd_tool",
        description: """
        Runs commands via Elixir's System.cmd/3 - NOT through a shell interpreter.
        Each entry in the `commands` array is executed directly as a process with
        its own `command` and `args`. The `operator` field determines how commands
        are combined: `|` pipes stdout between them, `&&` runs them sequentially.

        This is NOT a shell. Shell syntax (pipes, redirects, semicolons, subshells,
        env var expansion) has no meaning inside `command` or `args` fields. To pipe
        or chain commands, use the `operator` field with multiple `commands` entries.

        Use for: filesystem ops (rm, mv, mkdir), project commands (git, make, npm),
        and CLI tools needed for your task. Prefer specialized tools when available.
        Check tool availability with `which <tool>` or `command -v <tool>`.

        Execution context:
        - Working directory: the project's source root
        - No TTY - some commands behave differently
        - Glob patterns (*.ex, src/**/*.ts) are NOT expanded; pass literal paths
        - Environment variables are NOT expanded in args
        - Shell binaries (bash, sh, zsh) cannot be invoked directly
        - Interactive commands will hang and time out

        Approval rules:
        - File-modifying commands (awk, find -exec, patch) require user approval
        - Read-only sed (without -i/-f/e/w) is preapproved
        - Unapproved commands may be auto-denied if the user is not monitoring

        Command-specific notes:
        - rg: must include an explicit path arg when under '&&' or as first pipeline stage
        - wc: must have file args or receive pipeline input; '-' (stdin) is disallowed

        For commands that vary by OS (grep/sed), the current OS is: #{os_name} (#{os_family}).

        Available tools on PATH:
        #{available_tools()}

        Preapproved commands/patterns:
        #{allowed}
        #{user_prefixes}
        #{user_regexes}
        """,
        parameters: %{
          type: "object",
          required: ["description", "commands"],
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
              default: "&&",
              description: """
              Optional: Determines how the `commands` array entries are combined. Defaults to `&&` when omitted.
              `|` pipes stdout of each command into stdin of the next: cmd1 | cmd2 | cmd3
              `&&` runs commands sequentially, stopping on failure: cmd1 && cmd2 && cmd3
              The operator is inserted BETWEEN each entry in the `commands` array.
              Do NOT place the operator inside any command's `args`.
              """
            },
            commands: %{
              type: "array",
              description: """
              A list of commands to execute, combined using the `operator`.
              Each entry is a separate command stage with its own `command` and `args`.

              WRONG - do not embed shell operators in args:
              ```json
              [{"command": "git", "args": ["log", "--oneline", "|", "head", "-5"]}]
              ```
              The `|` above becomes a literal argument to `git`, not a pipe.

              CORRECT - pipeline (operator: "|"):
              ```json
              [
                {"command": "git", "args": ["log", "--oneline"]},
                {"command": "head", "args": ["-5"]}
              ]
              ```

              CORRECT - sequential (operator: "&&"):
              ```json
              [
                {"command": "mkdir", "args": ["-p", "out"]},
                {"command": "cp", "args": ["src/config.json", "out/"]}
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
                    description: """
                    The base command to execute, without any arguments or options.

                    MUST be either:
                    1. A bare command name on the user's PATH (e.g., "git", "rg", "npm")
                    2. An abs path **starting with `./`** within the project (eg "./fnord" or "./scripts/run-tests.sh")

                    Relative paths are NOT allowed for security reasons.
                    """
                  },
                  args: %{
                    type: "array",
                    description: """
                    A list of options to pass to the command.
                    DO NOT include the command itself.
                    """,
                    items: %{
                      type: "string",
                      description: """
                      A single argument or option for the command.
                      Do not escape or quote.
                      Env vars are NOT expanded.
                      Shell operators (|, &&, ;, >, <, >>) are NOT valid args.
                      To pipe or chain commands, use the `operator` field with
                      multiple entries in the `commands` array.
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
         {:ok, project} <- Store.get_project() do
      opts
      |> Map.get("operator", "&&")
      # NOTE: do NOT resolve commands before approvals; we want approvals to see
      # the literal command string (e.g. ./make) and we want missing commands to
      # error out cleanly without having to approve them first.
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
    opts
    |> Map.get("timeout_ms", @default_timeout_ms)
    |> to_integer()
    |> clamp_timeout()
  end

  # Coerce timeout value to integer. JSON decoders and LLMs may deliver
  # the value as a float (e.g. 300000.0) or string ("300000") even though
  # the spec declares it as integer. Params coercion handles the common
  # cases, but this is a safety net for any code path that bypasses it.
  defp to_integer(val) when is_integer(val), do: val
  defp to_integer(val) when is_float(val), do: trunc(val)

  defp to_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {i, ""} -> i
      _ -> @default_timeout_ms
    end
  end

  defp to_integer(_), do: @default_timeout_ms

  defp clamp_timeout(val) when val <= 0, do: @default_timeout_ms
  defp clamp_timeout(val) when val > @max_timeout_ms, do: @max_timeout_ms
  defp clamp_timeout(val), do: val

  # ----------------------------------------------------------------------------
  # Resolve commands to absolute paths where possible.
  # ----------------------------------------------------------------------------
  defp resolve_commands(commands, root) do
    commands
    |> Enum.reduce_while([], fn command, acc ->
      command
      |> find_executable(root)
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
  # Command resolution (project-aware)
  #
  # LLMs *love* `rg`, but they often forget to provide a path argument, even
  # when it's explicitly called out in the tool spec. This special case adds
  # the project's source_root as a path argument if no other path-like
  # arguments are provided. If the LLM provides a pattern arg that *looks* like
  # a path, and no other path-like args, we can't do anything sensible, since
  # we don't know *which* arg they borked, so we just let the command fail.
  # -----------------------------------------------------------------------------
  defp find_executable(command, root) when is_binary(command) do
    cond do
      String.starts_with?(command, "/") ->
        path = Path.expand(command)
        if executable?(path), do: {:ok, path}, else: {:error, :not_found}

      String.starts_with?(command, "~") ->
        path = Path.expand(command)
        if executable?(path), do: {:ok, path}, else: {:error, :not_found}

      String.starts_with?(command, "./") ->
        # explicit local relative path: interpret relative to project root, but only if it stays within
        # the project root after expansion (fail closed on ../ escapes).
        path = Path.expand(command, root)

        cond do
          Util.path_within_root?(path, root) and executable?(path) -> {:ok, path}
          true -> {:error, :not_found}
        end

      String.contains?(command, "/") ->
        # Any other slash-containing command is rejected: local execution must be explicit via "./".
        {:error, :not_found}

      true ->
        # bare command: resolve ONLY via PATH
        case System.find_executable(command) do
          nil -> {:error, :not_found}
          path -> {:ok, path}
        end
    end
  end

  defp find_executable(%{"command" => command, "args" => args} = cmd, root)
       when is_list(args) do
    if String.contains?(command, " ") do
      command
      |> find_executable(root)
      |> case do
        {:ok, resolved} ->
          {:ok, %{"command" => resolved, "args" => args}}

        # Try splitting on spaces and see if the first part is executable
        {:error, :not_found} ->
          [base | extra_args] = String.split(command, " ")

          case find_executable(base, root) do
            {:ok, resolved} -> {:ok, %{"command" => resolved, "args" => extra_args ++ args}}
            {:error, :not_found} -> {:error, "Command not found: #{format_command(cmd)}"}
          end
      end
    else
      case find_executable(command, root) do
        {:ok, resolved} -> {:ok, %{"command" => resolved, "args" => args}}
        {:error, :not_found} -> {:error, "Command not found: #{format_command(cmd)}"}
      end
    end
  end

  defp find_executable(%{"command" => _} = cmd, _root) do
    cmd
    |> Map.put("args", [])
    |> find_executable("")
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> :erlang.band(mode, 0o111) != 0
      _ -> false
    end
  end

  # ----------------------------------------------------------------------------
  # Context-aware validation for rg and wc
  # We fail-closed in two specific contexts to avoid timeouts and ambiguity:
  # - When operator is '&&': stdin is not piped, so commands must have explicit input.
  # - When operator is '|' and this is the first stage: no prior stdin exists yet.
  # In these cases:
  # - rg must include an explicit path-like positional arg (e.g., '.', './dir', '/abs', or a non-flag token).
  # - wc must include file args (non-flag tokens). Use of '-' (stdin) is disallowed because reading from stdin can hang the command.
  # Anywhere else, these commands are allowed (e.g., later stages in a pipeline).
  # ----------------------------------------------------------------------------
  defp validate_command_context(op, commands, root) do
    case op do
      "&&" ->
        if invalid_under_andand?(commands, root) do
          {:denied,
           """
           One or more commands require an explicit input source under '&&'.
           - rg must include an explicit path (e.g., '.' or a directory) when not reading from stdin.
           - wc must include file args (e.g., 'wc -l FILE') or '-' for stdin.
           Consider using a pipeline (|) or adding explicit args.
           """}
        else
          :ok
        end

      "|" ->
        case commands do
          [first | _] ->
            if invalid_first_stage?(first, root) do
              {:denied,
               "First stage requires an explicit input source:\n" <>
                 "- rg must include an explicit path (e.g., '.' or a directory).\n" <>
                 "- wc must include file args (e.g., 'wc -l FILE')."}
            else
              :ok
            end

          _ ->
            :ok
        end
    end
  end

  defp invalid_under_andand?(commands, root) do
    Enum.any?(commands, fn %{"command" => cmd, "args" => args} ->
      base = Path.basename(cmd)

      case base do
        "rg" -> not rg_has_pathlike_positional?(args, root)
        "wc" -> not has_files_only?(args)
        _ -> false
      end
    end)
  end

  defp invalid_first_stage?(%{"command" => cmd, "args" => args}, root) do
    base = Path.basename(cmd)

    case base do
      "rg" -> not rg_has_pathlike_positional?(args, root)
      "wc" -> not has_files_only?(args)
      _ -> false
    end
  end

  defp rg_has_pathlike_positional?(args, root) when is_list(args) do
    args
    |> rg_candidate_paths()
    |> Enum.any?(fn token ->
      path_token_within_root_exists?(token, root) || glob_within_root?(token, root)
    end)
  end

  defp rg_candidate_paths(args) when is_list(args) do
    args
    |> do_rg(false, false)
    |> Enum.reverse()
  end

  defp do_rg([], _after_dd, _pattern_seen), do: []
  defp do_rg(["--" | rest], _after_dd, pattern_seen), do: do_rg(rest, true, pattern_seen)
  defp do_rg(["-e", _pattern | rest], after_dd, _pattern_seen), do: do_rg(rest, after_dd, true)

  defp do_rg(["--regexp", _pattern | rest], after_dd, _pattern_seen),
    do: do_rg(rest, after_dd, true)

  defp do_rg([arg | rest], after_dd, pattern_seen) do
    cond do
      String.starts_with?(arg, "-") and not after_dd ->
        do_rg(rest, after_dd, pattern_seen)

      not pattern_seen ->
        do_rg(rest, after_dd, true)

      true ->
        [arg | do_rg(rest, after_dd, true)]
    end
  end

  defp path_token_within_root_exists?(token, root) do
    case expand_within_root(token, root) do
      {:ok, path} -> File.exists?(path)
      _ -> false
    end
  end

  defp expand_within_root(token, root) do
    expanded = Path.expand(token, root)

    if Util.path_within_root?(expanded, root) do
      {:ok, expanded}
    else
      {:error, :out_of_root}
    end
  end

  defp glob_within_root?(pattern, root) do
    pattern_path = Path.join(root, pattern)

    try do
      case Path.wildcard(pattern_path) do
        [] -> false
        matches -> Enum.any?(matches, &Util.path_within_root?(&1, root))
      end
    rescue
      _ in [ErlangError, ArgumentError] -> false
    end
  end

  # Helper for wc: file args (non-flag tokens) or '-' for stdin
  defp has_files_only?(args) when is_list(args) do
    Enum.any?(args, fn a -> not String.starts_with?(a, "-") end) &&
      not Enum.any?(args, &(&1 == "-"))
  end

  # ----------------------------------------------------------------------------
  # Execution and routing
  # ----------------------------------------------------------------------------

  # ----------------------------------------------------------------------------
  # The fact that this function exists at all is so, *so* frustrating.
  # ----------------------------------------------------------------------------
  defp route(op, commands, desc, timeout_ms, root) do
    # Preflight checks run before any encoding or execution so that all code
    # paths (including encoding-failure fallback) are covered.
    has_shell_invocation? =
      Enum.any?(commands, fn %{"command" => cmd, "args" => args} ->
        is_version_check? = "--version" in args
        is_shell? = Path.basename(cmd) in ~w(sh ash bash csh dash fish ksh tcsh zsh)
        is_shell? and !is_version_check?
      end)

    # The cmd_tool is available outside of edit mode, so we need to
    # double-check that the user actually wants to allow editing before
    # we let an apply_patch through.
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

    is_fnord_help? =
      Enum.count(commands) == 1 &&
        Enum.any?(commands, fn %{"command" => cmd, "args" => args} ->
          Path.basename(cmd) == "fnord" &&
            (Enum.any?(args, &String.contains?(&1, "help")) ||
               Enum.any?(args, &String.contains?(&1, "--help")) ||
               Enum.any?(args, &String.contains?(&1, "-h")))
        end)

    is_edit_mode? = Settings.get_edit_mode()

    cond do
      is_fnord_help? ->
        UI.info("Oof", "The LLM called cmd_tool for its own help text. Rerouting.")
        AI.Tools.SelfHelp.Cli.call(%{})

      # apply_patch check must come before the generic shell invocation denial,
      # because LLMs often wrap apply_patch in `bash -lc "apply_patch ..."` which
      # triggers both detections. We want to re-route to the RePatcher, not deny.
      is_edit_mode? and is_apply_patch? ->
        UI.info("Oof", "The LLM attempted to apply a patch with cmd_tool. Rerouting.")

        # Encode the commands for ApplyPatch - it expects a JSON patch string.
        # Wrap the result so the coordinator knows the changes were already
        # applied by the re-route. Without this, the coordinator sees a
        # cmd_tool success and may attempt the same edit again with stale
        # hashes, not realizing the file was already modified.
        json =
          case SafeJson.encode(commands, pretty: true) do
            {:ok, j} -> j
            _ -> inspect(commands)
          end

        case AI.Tools.ApplyPatch.call(%{"patch" => json}) do
          {:ok, msg} ->
            {:ok,
             "NOTE: Your apply_patch was intercepted and applied via file_edit_tool. " <>
               "The changes below have ALREADY been made to the file(s). " <>
               "Do NOT attempt to apply them again.\n\n#{msg}"}

          {:error, msg} ->
            {:error,
             "NOTE: Your apply_patch was intercepted and routed to file_edit_tool, " <>
               "but the edit failed. Some changes MAY have been partially applied. " <>
               "Re-read the target file(s) before deciding whether to retry.\n\n#{msg}"}
        end

      is_apply_patch? and not is_edit_mode? ->
        {:denied, "Cannot edit files; the user did not pass --edit."}

      has_shell_invocation? ->
        {:denied,
         """
         Execute commands directly; do not invoke through a shell.
         If you need specific shell features, write a temp script file
         and execute that directly.
         """}

      true ->
        run_as_shell_commands(op, commands, desc, timeout_ms, root)
    end
  end

  defp run_as_shell_commands(_, [%{"command" => "echo", "args" => [msg]}], _, _, _) do
    AI.Tools.Notify.call(%{"level" => "info", "message" => msg})
    {:ok, {"#{msg}\n", 0}}
  end

  defp run_as_shell_commands(op, commands, desc, timeout_ms, root) do
    case validate_command_context(op, commands, root) do
      {:denied, msg} ->
        {:denied, msg}

      :ok ->
        # Ask approvals about the original (unresolved) commands first. If approved,
        # resolve to concrete executables using the project root and then run.
        {op, commands, desc}
        |> Services.Approvals.confirm(:shell)
        |> case do
          {:ok, :approved} ->
            case resolve_commands(commands, root) do
              {:ok, resolved} -> run_pipeline(op, resolved, timeout_ms, root)
              {:error, reason} -> {:error, reason}
            end

          other ->
            other
        end
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

    UI.report_step("Executing command", format_command(command))

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
  @non_posix_tools_memo_table :cmd_tools_cache

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
