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
  def is_available?, do: UI.is_tty?()

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"cmd" => cmd}), do: {cmd, "..."}

  @impl AI.Tools
  def ui_note_on_result(%{"cmd" => cmd}, result) do
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

    {cmd,
     """
     #{result_str}
     #{additional}
     """}
  end

  @impl AI.Tools
  def spec do
    allowed =
      AI.Tools.Shell.Allowed.preapproved_cmds()
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    %{
      type: "function",
      function: %{
        name: "shell_tool",
        description: """
        Executes shell commands and returns the output. The user must approve
        execution of this command before it is run. The user may optionally
        approve the command for the entire session.

        The following commands (if present) are always allowed without approval:
        #{allowed}
        """,
        parameters: %{
          type: "object",
          required: ["description", "cmd"],
          properties: %{
            description: %{
              type: "string",
              description: """
              Explain to the user what the command does and why it is needed.
              This will be displayed to the user in the approval dialog.
              """
            },
            cmd: %{
              type: "string",
              description: "The complete command to execute."
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
  # Intercept disallowed shell syntax early and return an explicit error tuple
  # for clarity and consistency, rather than allowing a bare boolean to bubble up.
  def call(opts) do
    with {:ok, desc} <- AI.Tools.get_arg(opts, "description"),
         {:ok, cmd} <- AI.Tools.get_arg(opts, "cmd"),
         false <- AI.Tools.Shell.Util.contains_disallowed_syntax?(cmd),
         {:ok, cmd, system_args, approval_bits} <- validate_cmd(cmd) do
      timeout_ms =
        opts
        |> Map.get("timeout_ms", @default_timeout_ms)
        |> validate_timeout()

      if AI.Tools.Shell.Allowed.allowed?(cmd, approval_bits) do
        call_shell_cmd(cmd, system_args, timeout_ms)
      else
        with {:ok, :approved} <- confirm(desc, approval_bits, cmd, system_args) do
          call_shell_cmd(cmd, system_args, timeout_ms)
        end
      end
    else
      true -> {:error, "Command contains disallowed shell syntax"}
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
          System.cmd(cmd, args, opts)
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
      {:ok, {out, exit_code}} ->
        {:ok,
         """
         Command: `#{cmd} #{Enum.join(args, " ")}`
         Exit Status: `#{exit_code}`

         Output:

         #{String.trim_trailing(out)}
         """}

      {:exit, reason} ->
        {:error, "Command process exited: #{inspect(reason)}"}

      nil ->
        UI.debug("Command timed out after #{timeout_ms} ms")
        {:error, "Command timed out after #{timeout_ms} ms"}
    end
  end

  defp validate_cmd(cmd) do
    AI.Agent.ShellCmdParser.get_response(%{shell_cmd: cmd})
    |> case do
      {:ok, %{"cmd" => cmd, "args" => system_args, "approval_bits" => bits}} ->
        {:ok, cmd, system_args, bits}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_timeout(val) do
    cond do
      !is_integer(val) -> @default_timeout_ms
      val <= 0 -> @default_timeout_ms
      val > @max_timeout_ms -> @max_timeout_ms
      true -> val
    end
  end

  defp confirm(desc, approval_bits, cmd, args) do
    full_cmd = [cmd | args] |> Enum.join(" ")
    subject = Enum.join(approval_bits, " ")

    # Persistent approvals are not permitted for complex or arbitary shell
    # commands. Only simple commands that can be resolved to a single
    # executable (with subcommands) can be approved persistently.
    persistent =
      if match?(["sh" | _], approval_bits) do
        false
      else
        true
      end

    msg = [
      Owl.Data.tag("Execute a shell command:", [:green, :bright]),
      "\n\n",
      "  shell> ",
      Owl.Data.tag(full_cmd, [:black, :red_background])
    ]

    Services.Approvals.confirm(
      tag: "shell_cmd",
      subject: subject,
      persistent: persistent,
      detail: desc,
      message: msg
    )
  end
end
