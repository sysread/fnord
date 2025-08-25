defmodule AI.Tools.Shell do
  @moduledoc """
  A tool for executing shell commands with user approval.

  Delegates command approval logic to Services.Approvals, which provides
  hierarchical approval scopes (session, project, global) with persistence.
  Commands are parsed into approval bits that allow for granular approval
  of command families and subcommands.
  """

  @default_timeout_ms 30_000
  @max_timeout_ms 300_000

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"command" => cmd, "description" => desc}) do
    {"shell> #{cmd}", desc}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"command" => cmd}, result) do
    lines = String.split(result, ~r/\r\n|\n/)

    {result_str, additional} =
      if length(lines) > 10 do
        {first_lines, _rest} = Enum.split(lines, 10)
        remaining = length(lines) - 10

        {
          Enum.join(first_lines, "\n"),
          UI.italicize("...plus #{remaining} additional lines")
        }
      else
        {Enum.join(lines, "\n"), ""}
      end

    {"shell> #{cmd}",
     """
     #{result_str}
     #{additional}
     """}
  end

  @impl AI.Tools
  def spec do
    allowed =
      Services.Approvals.Shell.preapproved_cmds()
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    %{
      type: "function",
      function: %{
        name: "shell_tool",
        description: """
        Executes shell commands and returns the output.
        The user must approve execution of this command before it is run.
        The user may optionally approve simple commands for the entire session.

        Supports both simple commands and complex shell syntax:
        - Simple commands: "ls -la", "git log --oneline" (can be pre-approved)
        - Complex commands: "ls | grep foo", "find . -name '*.ex' | head -10" (require manual approval)

        The following simple commands are preapproved and will execute without requiring user approval:

        #{allowed}

        Notes:
        - Simple commands (no pipes, redirects, etc.) can be pre-approved for convenience
        - Complex commands with |, ;, &&, ||, >, <, $(), ` always require manual approval for security
        - Commands with complex operators bypass all pre-approval patterns

        Example usage:
        ```json
        {
          "description": "List files in the current directory",
          "command": "ls -la",
          "timeout_ms": 5000
        }
        ```

        ```json
        {
          "description": "Search for pattern and show first 10 results",
          "command": "rg 'pattern' | head -10",
          "timeout_ms": 10000
        }
        ```
        """,
        parameters: %{
          type: "object",
          required: ["description", "command"],
          properties: %{
            description: %{
              type: "string",
              description: """
              Explain to the user what the command does and why it is needed.
              This will be displayed to the user in the approval dialog.
              """
            },
            command: %{
              type: "string",
              description: """
              The complete shell command to execute. Can be simple (e.g., 'ls -la')
              or complex (e.g., 'find . -name "*.ex" | grep -v test').
              Complex commands with pipes, redirects, etc. will require manual approval.
              """
            },
            timeout_ms: %{
              type: "integer",
              description: """
              Optional execution timeout in milliseconds.
              Defaults to #{@default_timeout_ms}.
              Must be > 0 and ≤ #{@max_timeout_ms}.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(opts) do
    with {:ok, desc} <- AI.Tools.get_arg(opts, "description"),
         {:ok, command} <- AI.Tools.get_arg(opts, "command") do
      timeout_ms =
        opts
        |> Map.get("timeout_ms", @default_timeout_ms)
        |> validate_timeout()

      # Check for dangerous syntax that always requires manual approval
      if AI.Tools.Shell.Util.contains_disallowed_syntax?(command) do
        # Dangerous commands always require manual confirmation (bypass all pre-approvals)
        with {:ok, :approved} <- confirm_complex_command(desc, command) do
          call_shell_cmd_string(command, timeout_ms)
        end
      else
        # Simple commands use the existing approval logic
        case parse_simple_command(command) do
          {:ok, cmd, args} ->
            with {:ok, :approved} <- confirm_simple_command(desc, cmd, args) do
              call_shell_cmd_string(command, timeout_ms)
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      other -> other
    end
  end

  def call_shell_cmd(cmd, args, timeout_ms) do
    cwd =
      case Store.get_project() do
        {:ok, project} -> project.source_root
        _ -> nil
      end

    base_opts = [stderr_to_stdout: true, parallelism: true]

    opts =
      if is_binary(cwd) and cwd != "" do
        [{:cd, cwd} | base_opts]
      else
        base_opts
      end

    task =
      Task.async(fn ->
        try do
          # Wrap command in sh to prevent stdin hanging
          # Use proper shell escaping to handle spaces and special chars
          full_cmd = shell_escape([cmd | args])
          wrapped_cmd = "#{full_cmd} < /dev/null"
          System.cmd("sh", ["-c", wrapped_cmd], opts)
        rescue
          e in ErlangError ->
            case e.reason do
              :enoent -> {:error, "Command not found: #{cmd}"}
              :eaccess -> {:error, "Permission denied: #{cmd}"}
              other -> {:error, "Posix error: #{Atom.to_string(other)}"}
            end
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {out, exit_code}} when is_binary(out) ->
        {:ok,
         """
         shell> #{shell_escape([cmd | args])}
         ...$?> #{exit_code}
         ------
         #{String.trim_trailing(out)}
         """}

      {:ok, {:error, message}} ->
        {:error, message}

      {:exit, reason} ->
        {:error, "Command process exited: #{inspect(reason)}"}

      nil ->
        UI.debug(Enum.join([cmd | args], " "), "Command timed out after #{timeout_ms} ms")
        {:error, "Command timed out after #{timeout_ms} ms"}
    end
  end

  # Check if command contains complex shell operators that require manual approval
  # Parse simple command into cmd and args
  defp parse_simple_command(command) do
    case String.split(command, ~r/\s+/, parts: :infinity, trim: true) do
      [] ->
        {:error, "Empty command"}

      [cmd] ->
        {:ok, cmd, []}

      [cmd | args] ->
        {:ok, cmd, args}
    end
  end

  # Execute command string directly
  def call_shell_cmd_string(command, timeout_ms) do
    cwd =
      case Store.get_project() do
        {:ok, project} -> project.source_root
        _ -> nil
      end

    base_opts = [stderr_to_stdout: true, parallelism: true]

    opts =
      if is_binary(cwd) and cwd != "" do
        [{:cd, cwd} | base_opts]
      else
        base_opts
      end

    # During tests, run synchronously to avoid output capture issues
    # In production, use Task.async for timeout support
    if Application.get_env(:fnord, :test_mode, false) do
      # Synchronous execution for tests
      result =
        try do
          final_command =
            if needs_stdin_redirect?(command) do
              "#{command} < /dev/null"
            else
              command
            end

          System.cmd("sh", ["-c", final_command], opts)
        rescue
          e in ErlangError ->
            case e.reason do
              :enoent -> {:error, "Command not found"}
              :eaccess -> {:error, "Permission denied"}
              other -> {:error, "Posix error: #{Atom.to_string(other)}"}
            end
        end

      case result do
        {out, exit_code} when is_binary(out) ->
          {:ok,
           """
           shell> #{command}
           ...$?> #{exit_code}
           ------
           #{String.trim_trailing(out)}
           """}

        {:error, message} ->
          {:error, message}
      end
    else
      # Asynchronous execution with timeout for production
      task =
        Task.async(fn ->
          try do
            final_command =
              if needs_stdin_redirect?(command) do
                "#{command} < /dev/null"
              else
                command
              end

            System.cmd("sh", ["-c", final_command], opts)
          rescue
            e in ErlangError ->
              case e.reason do
                :enoent -> {:error, "Command not found"}
                :eaccess -> {:error, "Permission denied"}
                other -> {:error, "Posix error: #{Atom.to_string(other)}"}
              end
          end
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task) do
        {:ok, {out, exit_code}} when is_binary(out) ->
          {:ok,
           """
           shell> #{command}
           ...$?> #{exit_code}
           #{String.trim_trailing(out)}
           """}

        {:ok, {:error, message}} ->
          {:error, message}

        {:exit, reason} ->
          {:error, "Command process exited: #{inspect(reason)}"}

        nil ->
          UI.debug("Command timed out after #{timeout_ms} ms")
          {:error, "Command timed out after #{timeout_ms} ms"}
      end
    end
  end

  # Determine if command needs stdin redirect
  defp needs_stdin_redirect?(command) do
    # Don't add stdin redirect if command already has input handling
    not (String.contains?(command, "<") or String.contains?(command, "|"))
  end

  defp validate_timeout(val) do
    cond do
      !is_integer(val) -> @default_timeout_ms
      val <= 0 -> @default_timeout_ms
      val > @max_timeout_ms -> @max_timeout_ms
      true -> val
    end
  end

  # Properly escape shell arguments to prevent injection and handle spaces/special chars
  defp shell_escape(args) when is_list(args) do
    args
    |> Enum.map(&shell_escape_arg/1)
    |> Enum.join(" ")
  end

  # POSIX-safe shell argument escaping using the single quote trick
  # Handles ALL edge cases by ending quote, escaping single quote, restarting quote
  defp shell_escape_arg(arg) when is_binary(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  # Confirmation for complex commands (no pre-approval possible)
  defp confirm_complex_command(desc, command) do
    Services.Approvals.confirm({command, desc}, Services.Approvals.Shell)
  end

  # Confirmation for simple commands (existing approval logic)
  defp confirm_simple_command(desc, cmd, args) do
    command = Enum.join([cmd | args], " ")
    Services.Approvals.confirm({command, desc}, Services.Approvals.Shell)
  end
end
