defmodule AI.Tools.Shell do
  @moduledoc """
  A tool for executing shell commands with user approval.

  Delegates command approval logic to Services.Approvals, which provides
  hierarchical approval scopes (session, project, global) with persistence.
  Commands are parsed into approval bits that allow for granular approval
  of command families and subcommands.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: UI.is_tty?()

  @impl AI.Tools
  def read_args(args) do
    with {:ok, desc} <- AI.Tools.get_arg(args, "description"),
         {:ok, cmd} <- AI.Tools.get_arg(args, "cmd") do
      cmd = String.trim(cmd)

      cond do
        desc == "" ->
          {:error, :missing_argument, "description"}

        cmd == "" ->
          {:error, :missing_argument, "cmd"}

        true ->
          {:ok, %{"description" => desc, "cmd" => cmd}}
      end
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{"cmd" => cmd}), do: {"Shell", "# $ #{cmd}"}

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

    {"Shell",
     """
     # $ #{cmd}
     #{result_str}
     #{additional}
     """}
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "shell_tool",
        description: """
        Executes shell commands and returns the output. The user must approve
        execution of this command before it is run. The user may optionally
        approve the command for the entire session.

        The following commands are always allowed without approval:
        - `ls`
        - `pwd`
        - `find`
        - `cat`
        - `rg`
        - `ag`
        - `grep` (although take care, since it varies between bsd/macOS and GNU/Linux)
        """,
        parameters: %{
          type: "object",
          required: ["description", "cmd"],
          properties: %{
            description: %{
              type: "string",
              description: """
              Explain to the user what the command does and why it is needed.
              This will be displayed to the user in the approval dialog."
              """
            },
            cmd: %{
              type: "string",
              description: "The complete command to execute."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  # Intercept disallowed shell syntax early and return an explicit error tuple
  # for clarity and consistency, rather than allowing a bare boolean to bubble up.
  def call(args) do
    with {:ok, desc} <- AI.Tools.get_arg(args, "description"),
         {:ok, cmd} <- AI.Tools.get_arg(args, "cmd"),
         false <- AI.Tools.Shell.Util.contains_disallowed_syntax?(cmd),
         {:ok, %{"cmd" => cmd, "args" => args, "approval_bits" => bits}} <- validate(cmd),
         {:ok, :approved} <- confirm(desc, bits, cmd, args) do
      call_shell_cmd(cmd, args)
    else
      true -> {:error, "Command contains disallowed shell syntax"}
      other -> other
    end
  end

  defp call_shell_cmd(cmd, args) do
    cwd =
      with {:ok, project} <- Store.get_project() do
        project.source_root
      else
        _ -> File.cwd!()
      end

    try do
      System.cmd(cmd, args, stderr_to_stdout: true, parallelism: true, cd: cwd)
      |> case do
        {output, 0} -> {:ok, String.trim_trailing(output)}
        {output, _} -> {:error, String.trim_trailing(output)}
      end
    rescue
      e in ErlangError ->
        case e.reason do
          :enoent -> {:error, "Command not found: #{cmd}"}
          :eaccess -> {:error, "Permission denied: #{cmd}"}
          other -> {:error, "Posix error: #{Atom.to_string(other)}"}
        end
    end
  end

  defp validate(cmd) do
    AI.Agent.ShellCmdParser.get_response(%{shell_cmd: cmd})
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
