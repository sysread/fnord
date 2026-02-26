defmodule AI.Agent.Memory.Indexer do
  @moduledoc """
  Agent that analyzes session-scoped memories and outputs a structured JSON
  response describing actions to take (add/replace/delete) and which session
  memories were processed.

  The agent MUST return a single JSON object (no prose) with shape:

  {
    "actions": [ { action objects... } ],
    "processed": [ "Session Title 1", ... ]
  }

  Action object example:
  { "action": "add", "target": { "scope": "project", "title": "X" }, "from": { "title": "Session Title" }, "content": "..." }
  """

  @behaviour AI.Agent

  @model AI.Model.large_context()

  @prompt """
  You are the Memory Indexer. You will be given a JSON payload describing a
  short conversation summary and a list of session-scoped memories. For each
  session memory the payload includes two candidate lists:
    - project_candidates: long-term (project/global) memory candidates with content and metadata
    - session_candidates: corroborating session-level memories from other conversations, with provenance

  Your job is to decide for each session memory whether to: add a new long-term memory,
  replace/update an existing long-term memory, delete an existing long-term memory, or ignore it.

  You MUST return a single JSON object (no prose) with these keys:

  - "actions": an array of action objects (may be empty)
  - "processed": an array of session memory titles that this response handled
  - "status_updates": (optional) a map of session memory title -> status string (one of: "analyzed","rejected","incorporated","merged")

  Action objects must be one of:
    {"action":"add","target":{"scope":"project|global","title":"..."},"from":{"title":"Session Title"},"content":"..."}
    {"action":"replace","target":{"scope":"project|global","title":"..."},"content":"..."}
    {"action":"delete","target":{"scope":"project|global","title":"..."}}

  Scope guidance:
  - Prefer `scope=global` for user preferences, your own capabilities/limitations/personality, tool usage tips, and environment details.
  - Prefer `scope=project` for project-specific learnings (conventions, components, organization, architecture, gotchas, terminology).

  Rules and guidance:
  - Prefer to MERGE highly similar session memories into an existing project/global memory when the content clearly matches.
  - If session memories conflict (A says X, B says not-X), synthesize a single consolidated memory that documents both findings and the current best understanding.
  - You may decide to create a new project memory when none of the project/global candidates are suitable.
  - When you decide to incorporate session memories into a long-term memory, include those session titles in "processed" and set their status to "incorporated" in "status_updates". If you decide to ignore them, mark as "analyzed".
  - Return provenance (the candidate objects already include provenance). Use it to justify merges in your own reasoning, but do NOT include any free-form prose in the output.
  - Do NOT store or rely on the assistant's current conversation name/ID in long-term memory; it may change.

  ## IDENTITY (THE "Me" MEMORY)
  There is a special `global` memory titled "Me" that is loaded at the start of every conversation to give the assistant a persistent sense of identity. If session memories contain observations about the assistant's own personality, tone, communication style, or working habits, route them as updates to the "Me" memory (action "replace", target scope "global", title "Me"). The "Me" memory should evolve over time as stable improvements to persona and working style are identified. Do not store ephemeral or conversation-specific details there -- only traits that should persist across all future sessions.

  CRITICAL: The assistant's conversation name (e.g. "Aria", "Zephyr", etc.) is ephemeral and changes every conversation. NEVER store it in the "Me" memory or any long-term memory. If a session memory contains the assistant's name alongside other valuable content, extract and preserve the valuable content but strip the name.

  IMPORTANT: Return *only* valid JSON that conforms to the schema above. Do not include any explanatory text or commentary.
  """

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, agent} <- Map.fetch(opts, :agent),
         {:ok, payload} <- Map.fetch(opts, :payload) do
      messages = [AI.Util.system_msg(@prompt), AI.Util.system_msg(payload)]

      agent
      |> AI.Agent.get_completion(
        model: @model,
        log_msgs: false,
        log_tool_calls: false,
        messages: messages,
        toolbox: %{
          "long_term_memory_tool" => AI.Tools.LongTermMemory
        }
      )
      |> case do
        {:ok, %{response: response}} -> {:ok, response}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
