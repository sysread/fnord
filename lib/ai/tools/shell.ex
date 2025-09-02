defmodule AI.Tools.Shell do
  @default_timeout_ms 5_000
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
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"commands" => commands, "description" => desc} = args) do
    op = Map.get(args, "operator", "|")
    command = format_commands(op, commands)
    {"shell> #{command}", desc}
  end

  def ui_note_on_request(other) do
    {"shell", "Invalid JSON args: #{inspect(other)}"}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"commands" => commands} = args, result) do
    op = Map.get(args, "operator", "|")
    command = format_commands(op, commands)
    {"shell> #{command}", result}
  end

  @impl AI.Tools
  def spec do
    os = :os.type() |> IO.inspect(pretty: true)

    allowed =
      Services.Approvals.Shell.preapproved_cmds()
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    %{
      type: "function",
      function: %{
        name: "shell_tool",
        description: """
        Executes a series of shell commands, and returns the mixed STDOUT and STDERR output.

        ALWAYS prefer a built-in tool call over this tool when available.

        The user must approve execution of this command before it is run.
        It is essential to remember that you cannot launch interactive commands!
        Commands that require user input or interaction will fail after a timeout, resulting in a poor experience for the user.
        Individual commands may not include redirection, pipes, command substitution, or other complex shell operators.

        IMPORTANT: `sed`, `awk`, `find`, and other tools with the potential to
                   modify files ALL require explicit user approval on every
                   invocation. As a rule, if you can use a built-in tool to
                   accomplish the same thing, that is preferable, as the user
                   may not be babysitting this process.

        IMPORTANT: This uses elixir's System.cmd/3 to execute commands. It
                   *will* `cd` into the project's source root before executing
                   commands. Some commands DO behave differently without a tty.
                   For example, `rg` REQUIRES a path argument when not run in a
                   tty.

        For commands that vary based on OS, the current OS is: #{os}

        The following commands are preapproved and will execute without requiring user approval:
        #{allowed}
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
              description: """
              Optionally specifies whether commands are piped together (`|`) or
              run sequentially (&&). By default, commands are piped.
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
                    description: "A list of arguments and options to pass to the command.",
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
         timeout_ms <- validate_timeout(opts),
         {:ok, project} <- Store.get_project() do
      Map.get(opts, "operator", "|")
      |> route(commands, desc, timeout_ms, project.source_root)
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------

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
        is_apply_patch? = String.contains?(json, "apply_patch")
        is_edit_mode? = Settings.get_edit_mode()

        cond do
          is_edit_mode? and is_apply_patch? ->
            UI.info("Oof", "The LLM attempted to apply a patch with the shell_tool. Rerouting.")

            AI.Tools.ApplyPatch.call(%{
              "patch" => """
              The LLM actually tried to call a non-existent `apply_patch` command
              via the `shell_tool`. This was it's tool call, intended to be piped
              together in the shell. Please do your best with it.

              #{json}
              """
            })

          is_apply_patch? and not is_edit_mode? ->
            {:denied, "Cannot edit files; the user did not pass --edit."}

          true ->
            run_as_shell_commands(op, commands, desc, timeout_ms, root)
        end

      _ ->
        run_as_shell_commands(op, commands, desc, timeout_ms, root)
    end
  end

  # ----------------------------------------------------------------------------
  # This one is also super annoying since the file_contents_tool is already
  # available, and sed can be used to modify files, so we don't want to
  # auto-approve it.
  # ----------------------------------------------------------------------------
  defp run_as_shell_commands(_, [%{"command" => "sed", "args" => ["-n", range, file]}], _, _, _) do
    [start_line, end_line] = Regex.run(~r/^(\d+),(\d+)p$/, range, capture: :all_but_first)

    AI.Tools.File.Contents.call(%{
      "file" => file,
      "line_numbers" => true,
      "start_line" => String.to_integer(start_line),
      "end_line" => String.to_integer(end_line)
    })
    |> case do
      {:ok, content} -> {:ok, {content, 0}}
      {:error, reason} -> {:ok, {"Error reading file #{file}: #{reason}", 1}}
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

  defp run_pipeline(op, commands, timeout_ms, root, acc \\ nil)
  defp run_pipeline(_, [], _, _, acc), do: {:ok, acc || "(no output)"}

  defp run_pipeline(op, [command | rest], timeout_ms, root, acc) do
    input =
      case op do
        "|" -> acc
        "&&" -> nil
      end

    command =
      command
      |> special_case()

    command
    |> shell_out(timeout_ms, root, input)
    |> case do
      {:error, :not_found} ->
        {:ok, "Command not found: #{format_command(command)}"}

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

  defp find_executable(command) do
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

  defp shell_out(%{"command" => command, "args" => args}, timeout_ms, root, nil) do
    command
    |> find_executable()
    |> case do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, cmd} ->
        run_with_timeout(timeout_ms, fn ->
          {:ok, System.cmd(cmd, args, cd: root, stderr_to_stdout: true)}
        end)
    end
  end

  defp shell_out(%{"command" => command, "args" => args}, timeout_ms, root, stdin) do
    command
    |> find_executable()
    |> case do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, cmd} ->
        Util.Temp.with_tmp(stdin, fn tmp ->
          with :ok <- chmod_600(tmp),
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
  end

  # -----------------------------------------------------------------------------
  # LLMs *love* `rg`, but they often forget to provide a path argument, even
  # when it's explicitly called out in the tool spec. This special case adds
  # the project's source_root as a path argument if no other path-like
  # arguments are provided. If the LLM provides a pattern arg that *looks* like
  # a path, and no other path-like args, we can't do anything sensible, since
  # we don't know *which* arg they borked, so we just let the command fail.
  # -----------------------------------------------------------------------------
  defp special_case(%{"command" => "rg", "args" => args} = cmd) do
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
          %{"command" => "rg", "args" => args ++ [project.source_root]}
        else
          # This shouldn't be possible, but if it does happen, just return as-is
          _ -> cmd
        end

      _ ->
        cmd
    end
  end

  defp special_case(cmd), do: cmd

  defp chmod_600(path) do
    # Ensure stdin temp is not world/group readable regardless of umask
    File.chmod(path, 0o600)
  end

  defp run_with_timeout(timeout, fun, opts \\ []) do
    on_timeout = Keyword.get(opts, :on_timeout, fn -> :ok end)

    task =
      Task.async(fn ->
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

  defp validate_timeout(opts) do
    val = Map.get(opts, "timeout_ms", @default_timeout_ms)

    cond do
      !is_integer(val) -> @default_timeout_ms
      val <= 0 -> @default_timeout_ms
      val > @max_timeout_ms -> @max_timeout_ms
      true -> val
    end
  end

  defp format_commands(op, commands) do
    try do
      commands
      |> Enum.map(&format_command/1)
      |> Enum.join(" #{op} ")
    rescue
      _ -> "Invalid command list: #{inspect(commands, pretty: true)}"
    end
  end

  defp format_command(%{"command" => command, "args" => args}) do
    [command | args]
    |> Enum.join(" ")
  end

  defp format_command(invalid_format) do
    "Invalid command format: #{inspect(invalid_format, pretty: true)}"
  end
end
