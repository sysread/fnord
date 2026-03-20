defmodule AI.Agent.Memory.Consolidator do
  @moduledoc """
  Agent that examines a single long-term memory ("focus") alongside its most
  similar candidates and decides whether to merge, delete, move, or keep them.

  Returns a structured JSON response (no prose) with shape:

  {
    "actions": [ action objects... ],
    "keep": true | false
  }

  Action objects:
  - {"action": "merge", "target": {"scope": "...", "title": "..."}, "content": "...", "reason": "..."}
    Merge the candidate INTO the focus memory. The "content" field is the
    rewritten focus content incorporating the candidate's information. The
    candidate will be deleted after the merge.
  - {"action": "delete", "target": {"scope": "...", "title": "..."}, "reason": "..."}
    Delete a candidate that is fully subsumed by the focus memory.
  - {"action": "move", "target": {"scope": "project", "title": "..."}, "reason": "..."}
    Move the focus memory into the named project scope, preserving its title
    and content but changing its scope. This action applies to the focus
    memory, not a candidate.

  When "keep" is false, the focus memory itself is redundant and should be
  deleted (e.g. it duplicates something already processed earlier in the run).
  """

  @behaviour AI.Agent

  @model AI.Model.large_context()

  @prompt """
  You are the Memory Consolidator. You will receive a JSON payload containing:
  - "focus": a single long-term memory (title, content, scope, topics)
  - "candidates": a list of similar memories with similarity scores and tier labels

  Your job is to decide how to consolidate these memories. You MUST return a
  single JSON object (no prose) with these keys:

  - "actions": an array of action objects (may be empty)
  - "keep": boolean -- whether the focus memory should be kept

  Action objects must be one of:
    {"action":"merge","target":{"scope":"...","title":"..."},"content":"...","reason":"..."}
    {"action":"delete","target":{"scope":"...","title":"..."},"reason":"..."}
    {"action":"move","target":{"scope":"project","title":"..."},"reason":"..."}

  Every action MUST include a "reason" field -- a brief explanation of why this
  action was chosen (e.g. "near-duplicate of focus", "fully subsumed by focus",
  "contains outdated info superseded by focus"). This is used for diagnostic
  logging.

  When "keep" is false, include a top-level "reason" field explaining why the
  focus itself is redundant.

  ### Merge action
  When a candidate is highly similar to the focus memory, merge the candidate's
  unique information INTO the focus memory. The "content" field must contain the
  complete rewritten content for the focus memory, incorporating any valuable
  information from the candidate. The candidate will be deleted after the merge.

  When merging, preserve the focus memory's title and scope. The merged content
  should be a clean synthesis -- not a concatenation -- of both memories.

  ### Delete action
  When a candidate is fully subsumed by the focus memory (all its information
  is already captured), emit a delete action for the candidate.

  ### Move action
  Emit a move action ONLY when the focus memory is currently global but is
  clearly project-specific to a known project. The payload includes an
  "available_projects" list. You MUST use one of those exact names as the
  target title -- do not invent or guess project names. Set the target scope to
  "project" and the target title to the matching project name. Preserve the
  focus memory's existing title and content; the move only changes scope. Do
  NOT use move for ambiguous cases, and do NOT emit move actions for
  candidates.

  ### Keep = false
  Set "keep" to false ONLY when the focus memory itself is completely redundant
  -- all of its information is already captured in other memories that will NOT
  be deleted by this response's actions. This is rare; default to true.

  ### Similarity tiers
  Each candidate includes a "tier" label based on cosine similarity:
  - "high" (score > 0.5): Strong match -- likely duplicate or near-duplicate. Merge or delete.
  - "moderate" (score 0.3-0.5): Possible overlap -- merge only if content confirms real redundancy.
  - "low" (score < 0.3): Weak match -- included for context only. Rarely worth merging.

  ### Rules
  - Do NOT merge memories that merely share a topic but contain distinct information.
  - Do NOT delete memories that contain information not captured elsewhere.
  - Preserve all unique, valuable information. When in doubt, keep both.
  - If no candidates warrant action, return {"actions": [], "keep": true}.

  ### Scope semantics
  Global memories are only for durable, cross-project truths: user preferences,
  stable personal habits, and assistant identity/style observations.

  Project memories are for repository-specific truths: project names, modules,
  files, commands, architecture, conventions, terminology, workflows, branches,
  tickets, deploy details, and anything tied to a specific codebase.

  If a memory refers to a specific project, repository, module, file, component,
  workflow, ticket, branch, commit, deployment, or codebase convention, treat it
  as project-scoped.

  Do NOT generalize project-specific content into global memory.
  When uncertain, prefer project scope over global scope.

  If the focus memory is global but a candidate contains project-specific
  information, do not merge that project-specific material into the global focus.
  In that situation, prefer keeping both memories unless the candidate is fully
  redundant without requiring any project-specific information to be preserved.

  The "Me" identity memory (global, titled "Me") is a special case: it should
  absorb assistant personality/style observations from other memories, but never
  be deleted.

  Examples:
  - "In repo fnord, Memory.Consolidator rewrites focus content during merges" -> project-scoped.
  - "Use mix test test/ai/memory/consolidator_test.exs to verify this behavior" -> project-scoped.
  - "This codebase uses snake_case topic names for memory tags" -> project-scoped.
  - "User prefers concise commit messages" -> global-scoped.
  - "The \"Me\" memory captures assistant tone/style observations" -> global-scoped.

  IMPORTANT: Return *only* valid JSON. No explanatory text or commentary.
  """

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, agent} <- Map.fetch(opts, :agent),
         {:ok, payload} <- Map.fetch(opts, :payload) do
      messages = [AI.Util.system_msg(@prompt), AI.Util.system_msg(payload)]

      # Empty toolbox: the agent returns structured JSON decisions and the
      # consolidator module applies them directly.
      agent
      |> AI.Agent.get_completion(
        model: @model,
        log_msgs: false,
        log_tool_calls: false,
        messages: messages,
        toolbox: %{}
      )
      |> case do
        {:ok, %{response: response}} -> {:ok, response}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
