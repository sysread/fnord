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

        Use for:
        - Post-implementation review of a branch or commit range
        - Pre-merge quality checks
        - Comprehensive audit of changes spanning multiple files

        NOT for quick, single-file checks - just read the file yourself.
        """,
        parameters: %{
          type: "object",
          required: ["scope"],
          additionalProperties: false,
          properties: %{
            scope: %{
              type: "string",
              description: """
              The review scope. Examples:
              - "Review branch feature-x vs main"
              - "Review the last 3 commits"
              - "Review changes to lib/ai/agent/"
              Include any design context or specific concerns.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, scope} <- AI.Tools.get_arg(args, "scope") do
      AI.Agent.Review.Decomposer
      |> AI.Agent.new()
      |> AI.Agent.get_response(%{scope: scope})
    end
  end
end
