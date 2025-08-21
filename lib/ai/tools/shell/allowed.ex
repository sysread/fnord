defmodule AI.Tools.Shell.Allowed do
  @moduledoc """
  Pattern-based allow-list of allowed commands and subcommands.

  This module defines a single source of truth for which shell commands
  and subcommands are authorized for execution. To extend the allow-list,
  update the `@allowed_patterns` list.

  Patterns can be:
    - Exact strings: "ls", "pwd"
    - Regex patterns: "m/git .*/", "m/docker (build|ps)/"

  Functions:
    * allowed_patterns/0    - Returns the list of allowed patterns
    * preapproved_cmds/0    - Returns a flat list of all approved invocations
    * allowed?/2            - Checks if a parsed command is authorized
  """

  @allowed_patterns [
    # Common utilities (allow all usage)
    "ag",
    "cat",
    "diff",
    "fgrep",
    "grep",
    "head",
    "jq",
    "ls",
    "nl",
    "pwd",
    "rg",
    "tac",
    "tail",
    "touch",
    "tree",
    "wc",

    # Git (specific subcommands only)
    "git branch",
    "git diff",
    "git grep",
    "git log",
    "git show",
    "git status"
  ]

  @spec allowed_patterns() :: [String.t()]
  def allowed_patterns, do: @allowed_patterns

  @spec preapproved_cmds() :: [String.t()]
  def preapproved_cmds do
    [
      # Common utilities (examples)
      "ag",
      "cat",
      "diff",
      "fgrep",
      "grep",
      "head",
      "jq",
      "ls",
      "nl",
      "pwd",
      "rg",
      "tac",
      "tail",
      "touch",
      "tree",
      "wc",
      # Git specific subcommands
      "git branch",
      "git diff",
      "git grep",
      "git log",
      "git show",
      "git status"
    ]
  end

  @spec allowed?(String.t(), [String.t()]) :: boolean()
  def allowed?(full_cmd, approval_bits) when is_binary(full_cmd) and is_list(approval_bits) do
    subject = Enum.join(approval_bits, " ")

    Enum.any?(@allowed_patterns, fn pattern ->
      matches_pattern?(pattern, subject)
    end)
  end

  # Check if a subject matches an allowed pattern
  defp matches_pattern?(pattern, subject) do
    if String.starts_with?(pattern, "m/") and String.ends_with?(pattern, "/") do
      # It's a regex pattern - extract the pattern between m/ and /
      raw_pattern = String.slice(pattern, 2..-2//1)

      # Anchor pattern to match from start of string
      anchored_pattern = "^" <> raw_pattern

      case Regex.compile(anchored_pattern) do
        {:ok, regex} -> Regex.match?(regex, subject)
        _ -> false
      end
    else
      # Plain string becomes prefix pattern allowing additional arguments
      escaped_pattern = Regex.escape(pattern)
      regex_pattern = "^#{escaped_pattern}(\\s.*|$)"

      case Regex.compile(regex_pattern) do
        {:ok, regex} -> Regex.match?(regex, subject)
        _ -> false
      end
    end
  end
end
