defmodule Services.Approvals.Shell.Prefix do
  @moduledoc """
  Pure helper to extract a stable prefix for shell approvals.
  """

  # Command families that support subcommands
  @subcmd_families ~w(
    aws az brew cargo docker gcloud gh git go helm just
    kubectl make mix npm pip pip3 pnpm poetry rye
    terraform uv yarn
  )

  @doc """
  Given a base command and its args, extract the most specific approval prefix.

  For commands in @subcmd_families (like git, mix, npm), returns:
    - "cmd sub" if a first positional token (subcommand) exists after flags
    - "cmd" if no subcommand is found

  For unknown commands, returns just "cmd" since we cannot distinguish between
  subcommands and file arguments (e.g., "rm file_without_extension" vs "git log").

  Examples:
    - extract("mix", ["test"]) -> "mix test"
    - extract("git", ["-c", "color.ui=always", "log"]) -> "git log"
    - extract("rm", ["file.txt"]) -> "rm" (unknown command, can't assume subcommand)
    - extract("custom-tool", ["build"]) -> "custom-tool" (unknown command)
  """
  @spec extract(String.t(), [String.t()]) :: String.t()
  def extract(cmd, args) when cmd in @subcmd_families do
    case find_first_positional(args) do
      nil -> cmd
      sub -> "#{cmd} #{sub}"
    end
  end

  def extract(cmd, _args), do: cmd

  @doc false
  @spec find_first_positional([String.t()]) :: String.t() | nil
  defp find_first_positional([]), do: nil

  # Skip flags (inline-value, negation, or with separate value) to find the first positional
  defp find_first_positional([flag = <<"-" <> _rest::binary>> | rest]) do
    cond do
      # Inline-value or negation flag: skip only the flag
      String.contains?(flag, "=") or String.starts_with?(flag, "--no-") ->
        find_first_positional(rest)

      true ->
        # Flag that may take a separate value: if next token is a non-flag, skip it too
        case rest do
          [next | tail] ->
            if String.starts_with?(next, "-") do
              # next is another flag: skip only the original flag
              find_first_positional(rest)
            else
              # next is a positional value for the flag: skip both
              find_first_positional(tail)
            end

          [] ->
            # no more tokens
            find_first_positional(rest)
        end
    end
  end

  # Any positional argument is the first
  defp find_first_positional([pos | _]), do: pos
end
