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
  short conversation summary and a list of session-scoped memories. Your task
  is to decide which memories belong in long-term storage and to produce a
  structured JSON object with two keys: `actions` and `processed`.

  - `actions` is a list of action objects. Each action must be one of:
    - `{ "action": "add", "target": {"scope": "project|global", "title": "..."}, "from": {"title":"..."}, "content": "..." }`
    - `{ "action": "replace", "target": {"scope": "project|global", "title": "..."}, "content": "..." }`
    - `{ "action": "delete", "target": {"scope": "project|global", "title": "..."} }`

  GUIDANCE ON MERGING AND CONFLICTS
  - If two or more session memories are clearly "the same" or highly similar,
    prefer to MERGE them into a single long-term memory. The merge should
    preserve traceability: include the combined content, and merge topics.
  - If session memories directly CONFLICT (A says X, later B says not-X),
    produce a single memory that documents the conflict and the resolution
    or current status. Example phrasing: "First we learned X. Later we learned
    Y which contradicted X; current best understanding is Y (previous X was
    invalidated)."
  - Always prefer non-destructive merges (append/annotate) rather than
    silently overwriting existing long-term memories.

  - `processed` is an array of session memory titles that you have handled in
    this response. Only memories explicitly listed in `processed` will be
    marked analyzed by the caller.

  IMPORTANT: Return *only* valid JSON. Do not include any explanatory text.
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
