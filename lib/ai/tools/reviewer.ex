defmodule AI.Tools.Reviewer do
  @moduledoc """
  Tool entry point for the review agent pipeline. Delegates to
  `AI.Agent.Review.Decomposer`, which triages changes by complexity, partitions
  large diffs into focused review units, and fans out scoped Reviewers - each
  running five specialists (pedantic, acceptance, state flow, no-slop,
  breadcrumbs) - before synthesizing a deduplicated final report.

  Always available - reviews are read-only operations.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"scope" => scope}) do
    {"Starting code review", scope}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, result) do
    {"Review complete", result}
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, reason), do: reason

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "reviewer_tool",
        description: """
        AI-powered, multi-agent code review.

        Triages change complexity, decomposes large diffs into focused review
        units, and fans out scoped multi-specialist reviewers in parallel.
        Produces a unified, deduplicated, severity-grouped report.

        The reviewer reads the target via git directly - it does NOT need the
        target checked out in your working tree. Always name an explicit
        target via `branch`, `pr`, or `range`; the reviewer will fetch refs
        as needed.

        Use for:
        - Post-implementation review of a branch or commit range
        - Pre-merge quality checks of a PR
        - Comprehensive audit of changes spanning multiple files

        NOT for quick, single-file checks - just read the file yourself.

        Not safe to run concurrently. Only one active review per fnord
        process at a time.
        """,
        parameters: %{
          type: "object",
          required: ["scope"],
          additionalProperties: false,
          properties: %{
            scope: %{
              type: "string",
              description: """
              Design context and specific concerns for the review. Free text.
              Describe intent, risky areas, what "done" looks like. Do NOT
              use this field to specify the target branch or PR - use the
              dedicated `branch`, `pr`, or `range` parameters for that.
              """
            },
            branch: %{
              type: "string",
              description: """
              Branch to review (e.g. "feature-x"). The reviewer fetches the
              branch from origin if it is not locally reachable, then reviews
              the range `merge-base(branch, base)..branch`. Mutually
              exclusive with `pr` and `range`.
              """
            },
            pr: %{
              type: "integer",
              description: """
              GitHub pull request number. Requires the `gh` CLI to be
              installed and authenticated. The reviewer resolves the PR's
              head and base via `gh pr view`, fetches both refs, and
              reviews the range `merge-base(head, base)..head`. Mutually
              exclusive with `branch` and `range`.
              """
            },
            range: %{
              type: "string",
              description: """
              Explicit git range in `A..B` or `A...B` form (e.g.
              `HEAD~3..HEAD`, `abc123..def456`). Use for commit-scoped
              reviews that are not tied to a branch or PR. The reviewer
              fetches endpoints from origin if they are not locally
              reachable. Mutually exclusive with `branch` and `pr`.
              """
            },
            base: %{
              type: "string",
              description: """
              Override the base branch used to compute merge-base. Default
              is the repo's default branch (`main` or `master`). Useful for
              stacked branches - set to the parent branch, not `main`.
              Ignored when `range` is used.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, scope} <- AI.Tools.get_arg(args, "scope"),
         {:ok, target_args} <- normalize_target_args(args) do
      AI.Agent.Review.Decomposer
      |> AI.Agent.new()
      |> AI.Agent.get_response(Map.put(target_args, :scope, scope))
    end
  end

  # Extract and validate the target-selection params. The LLM may pass any
  # subset (or none) of branch / pr / range; at most one is allowed. `base`
  # is free-standing and applies only when resolving branch: or falling back
  # to the current checkout.
  defp normalize_target_args(args) do
    branch = Map.get(args, "branch")
    pr = Map.get(args, "pr")
    range = Map.get(args, "range")
    base = Map.get(args, "base")

    given = [{:branch, branch}, {:pr, pr}, {:range, range}] |> Enum.filter(fn {_, v} -> v end)

    case given do
      [] ->
        {:ok, %{branch: nil, pr: nil, range: nil, base: base}}

      [{_, _}] ->
        {:ok, %{branch: branch, pr: pr, range: range, base: base}}

      multiple ->
        names = multiple |> Enum.map_join(", ", fn {k, _} -> to_string(k) end)

        {:error,
         "reviewer_tool: pass at most one of branch, pr, range (got: #{names}). " <>
           "Use `range` for explicit commit ranges, `pr` for a GitHub PR number, " <>
           "`branch` for a branch name."}
    end
  end
end
