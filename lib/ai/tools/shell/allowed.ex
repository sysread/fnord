defmodule AI.Tools.Shell.Allowed do
  @moduledoc """
  Flexible, map-based allow-list of allowed commands and subcommands.

  This module defines a single source of truth for which shell commands
  and subcommands are authorized for execution. To extend the allow-list,
  update the `@allowed_commands` map.

  Data structure:
    %{
      "cmd" => :all | ["sub1", "sub2"],
      "docker" => ["run", "ps"],
      "echo" => :all,
      ...
    }

  Functions:
    * allowed_commands/0    - Returns the map of commands to allowed subcommands
    * preapproved_cmds/0    - Returns a flat list of all approved invocations
    * allowed?/2            - Checks if a parsed command is authorized
  """

  @allowed_commands %{
    # Common utilities
    "ag" => :all,
    "cat" => :all,
    "diff" => :all,
    "fgrep" => :all,
    "grep" => :all,
    "head" => :all,
    "jq" => :all,
    "ls" => :all,
    "nl" => :all,
    "pwd" => :all,
    "rg" => :all,
    "tac" => :all,
    "tail" => :all,
    "touch" => :all,
    "tree" => :all,
    "wc" => :all,

    # Git
    "git" => [
      "log",
      "diff",
      "status",
      "branch",
      "tag"
    ]
  }

  @type allowed_cmds_map :: %{String.t() => :all | [String.t()]}

  @spec allowed_commands() :: allowed_cmds_map
  def allowed_commands, do: @allowed_commands

  @spec preapproved_cmds() :: [String.t()]
  def preapproved_cmds do
    @allowed_commands
    |> Enum.flat_map(fn
      {cmd, :all} -> [cmd]
      {cmd, subs} when is_list(subs) -> Enum.map(subs, &"#{cmd} #{&1}")
    end)
  end

  @spec allowed?(String.t(), [String.t()]) :: boolean()
  def allowed?(full_cmd, approval_bits) when is_binary(full_cmd) and is_list(approval_bits) do
    exe = Path.basename(full_cmd)

    case Map.fetch(@allowed_commands, exe) do
      {:ok, :all} ->
        true

      {:ok, subs} when is_list(subs) ->
        case approval_bits do
          [_exe, sub | _] -> sub in subs
          _ -> false
        end

      :error ->
        false
    end
  end
end
