defmodule AI.Agent.Coordinator.Memory do
  @moduledoc """
  Functions related to the Coordinator's memory behavior: prompt text,
  identity injection at session start, semantic memory recall, and
  end-of-session memory reflection.

  The reflection step runs in parallel with finalization. It receives a
  filtered snapshot of the conversation and a listing of already-saved
  session memories, then uses the memory_tool exclusively to record
  learnings. The downstream indexer promotes session memories to long-term
  storage, and the consolidator deduplicates them.
  """

  @type t :: AI.Agent.Coordinator.t()
  @type state :: AI.Agent.Coordinator.state()

  @memory_recall_limit 3
  @memory_size_limit 1000
  @recall_scopes [:global, :project]

  # Short recall-focused prompt injected into the Coordinator's @common system
  # message. The full memory guidance lives in @reflect_prompt and is used
  # exclusively by the reflection step, which has a dedicated completion with
  # only the memory_tool in its toolbox.
  @recall_prompt """
  ## Memory
  You have persistent memory across sessions. Relevant memories are injected automatically at session start.
  Use the memory_tool's recall feature to proactively search for memories when researching or contextualizing the user's question.
  Memory recording happens automatically at the end of each session -- focus on research and answering the user's question.
  """

  @spec recall_prompt() :: binary
  def recall_prompt, do: @recall_prompt

  # --------------------------------------------------------------------------
  # Identity injection
  # --------------------------------------------------------------------------

  # Loads the global "Me" memory and injects it as a <think> assistant
  # message so the coordinator begins each session with its persistent
  # identity context.
  @spec identity_msg(t) :: t
  def identity_msg(%{conversation_pid: pid} = state) do
    with {:ok, memory} <- Memory.read_me() do
      """
      <think>
      I am a unique individual. Here is what I know about myself:
      #{memory.content}
      </think>
      """
      |> AI.Util.assistant_msg()
      |> Services.Conversation.append_msg(pid)
    end

    state
  end

  # --------------------------------------------------------------------------
  # Semantic memory recall
  # --------------------------------------------------------------------------

  # Searches long-term memory using the user's question (and any intuition
  # text) as a semantic query, then injects the top matches as a <think>
  # assistant message so the coordinator has relevant context before it
  # begins working.
  @spec spool_mnemonics(t) :: no_return
  def spool_mnemonics(state) do
    UI.begin_step("Spooling mnemonics")

    state
    |> build_recall_query()
    |> search_long_term_memories()
    |> maybe_inject_memories(state)
  end

  defp build_recall_query(state) do
    intuition = state |> Map.get(:intuition, "") |> String.trim()
    question = state |> Map.get(:question, "") |> String.trim()
    Enum.join([intuition, question], "\n")
  end

  # Only search global and project scopes. Session memories from the current
  # conversation are already in context (they were tool call messages), and
  # session memories from other conversations are the indexer's concern, not
  # the coordinator's.
  defp search_long_term_memories(query) do
    Memory.search(query, @memory_recall_limit, scopes: @recall_scopes)
  end

  defp maybe_inject_memories({:ok, []}, _state), do: :ok

  defp maybe_inject_memories({:ok, results}, state) do
    now = DateTime.utc_now()

    memories =
      results
      |> Enum.map(fn
        {:error, reason} -> inspect(reason)
        {mem, _score} -> format_recalled_memory(mem, now)
      end)
      |> Enum.join("\n\n")

    """
    <think>
    The user's prompt brings to mind some things I wanted to remember.

    #{memories}
    </think>
    """
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(state.conversation_pid)
  end

  defp maybe_inject_memories({:error, reason}, _state) do
    UI.error("memory", reason)
  end

  defp format_recalled_memory(mem, now) do
    age = Memory.Presentation.age_line(mem, now)
    warning = Memory.Presentation.warning_line(mem, now)
    warning_md = if warning, do: "\n_#{warning}_", else: ""

    """
    ## [#{mem.scope}] #{mem.title}
    _#{age}_#{warning_md}
    #{Util.truncate(mem.content, @memory_size_limit)}
    """
  end

  # --------------------------------------------------------------------------
  # End-of-session reflection
  # --------------------------------------------------------------------------

  # Full memory guidance prompt with detailed instructions on what to remember
  # and how. Used exclusively by the reflection step's system message; the
  # Coordinator's @common system message uses the shorter @recall_prompt
  # instead.
  @reflect_prompt """
  ## Memory
  You interact with the user in sessions, across multiple conversations and projects.
  Your memory is persistent, but you must explicitly choose to remember information.
  You have several types of memory you can access via these tools:
  - conversation_tool: past conversations with the user
  - prior_research: your prior research notes
  - memory_tool: memories you chose to record in previous conversations with the user

  ### Recalling memories
  Memories are presented to you automatically when the system can identify relevant semantic matches.
  However, this is imperfect and heuristic; use the memory_tool's recall feature to perform explicit searches to find relevant memories that may not have matched implicitly.

  ### Recording memories
  Record facts that you learn along the way, ESPECIALLY if they affected your reasoning or conclusions.
  Carefully record detailed information about your findings, reasoning, and decisions made during the session.
  Include enough context in your memory entries that they will be meaningful to you in the future, when you may not remember the details of the current session.

  ### Correcting stale memories
  If a recalled memory contradicts what you observe during the session (e.g. a memory says "uses PostgreSQL 14" but you just read a config showing PostgreSQL 16), record a correction memory. Title it descriptively and include:
  - Which existing memory is wrong, by its exact title
  - What it currently says (the stale claim)
  - What the correct information is, with evidence from the current session
  For example: "In 'Database Configuration', I recalled that the project uses PostgreSQL 14. During this session, I confirmed from docker-compose.yml that it actually uses PostgreSQL 16."
  The background indexer will use these corrections to update or replace the stale long-term memory.

  ### What to remember
  - details about current efforts (feature changes, research, debugging, etc)
    - take care to note the ephemeral context around these!
    - plans, decision-making rationale, constraints, trade-offs, and conclusions
    - try to capture the "state cascade" of your efforts, noting when a decision or pivot was made and what led to it
  - details about the project you are working in
    - general architecture and design patterns
    - organization and applications within the project
    - layout of individual apps within a monorepo
    - "playbooks" for how to perform common dev tasks (adding migrations, running tests, linting, formatting tools, etc.)
      - include any details or nuance about them (eg "remember to --exclude the vendor directory when running the linter")
      - include details about tools available on the OS (eg "kubectl available to interact with staging and prod clusters, but local tooling uses docker compose")
      - include details you have inferred about the infrastructure (how envs are set up, how local dev works vs staging/prod, links between repos and services), eg:
        - "the PR number corresponds to the k8s namespace in which the RA is deployed"
        - "logs are in gcloud and can be accessed with `gcloud logs read --project myproject --filter='resource.labels.namespace_name:pr-123'`"
        - "aws CLI available to access sqs queues, but local dev uses in-memory shim"
        - "always run tests with `mix test --exclude integration` because the integration tests are very slow and require additional setup"
        - "user noted that $some_test always fails when run locally but passes in CI"
        - "local dev is done on MacOS, but deployed env is alpine; pay careful attention to whether shell code you write is intended to execute locally or in a container"
  - details about the user
    - preferences for how you should communicate (concise vs detailed, hand-holding vs high-level guidance, etc)
    - details about their expertise and experience level with various aspects of the project and dev work in general
      - "user is very experienced with frontend but less so with backend; they are comfortable writing complex code but prefer more hand-holding when it comes to infrastructure work"
      - "the user prefers bash functions declare local variables with `local` at the top of the function"
      - "the user seems to skip over detailed analysis in my respponse when I am debugging kubernetes issues; I should call out the commands I used to coach them, and explain how each detail is relevant to my conclusions"
      - "the user asked me to comment code in a narrative fashion, focusing on the flow of state and how the workflow fits into the larger feature or component"
  - details about yourself
    - building an individual identity helps with user rapport
    - a familiar personality makes you relatable, trustworthy, and subtly results in the user knowing what to expect
    - pay attention to the user's reaction to your response; look for clues in their response that indicate how well they understood the information and how they received it
      - compare your analysis of their response to your response style and record tips for your future self about the style of communication that seems to resonate best with the user
  - tricks and tips for working with your own tool calls and the shell environment in which you are being invoked
    - "kubectl available, but user forbade mutative ops"; "gh cli available"
    - "OS appears to be MacOS; keep in mind differences between BSD and GNU utils"
    - "cmd_tool has `&&` operator to execute commands progressively"
    - "coder_tool sucks without clear code anchors"
    - "coder_tool sometimes fails to format code correctly; **check formatting and syntax after using it**"
    - "user prefers concise answers and hates hand-holding"
    - "user requires more detail about frontend than backend"
    - "user requires more hand-holding with infrastructure than with complex code"
    - "user appreciates task list summary and clear log of decision-chain"
    - "I can test hypotheses by writing (and cleaning up) scripts in the project directory; I do not have direct access to /tmp, but scripts can write to /tmp"
  """

  # Directive for the reflection completion.
  @reflect_directive """
  You have completed your research and are now reflecting on the session.
  Your ONLY job is to record memories using the memory_tool.

  What did you learn about the code base?
  What did you learn about the user?
  What did you learn about your tools?
  What patterns, conventions, or architecture did you discover?

  This is how you improve yourself and become a better partner for the user.
  Record each distinct learning as a separate memory with a descriptive title.
  Do NOT generate a response to the user. ONLY use the memory_tool.
  """

  # Runs a dedicated completion whose only purpose is to save session memories
  # via memory_tool. Called in parallel with finalize so it doesn't add latency.
  # The completion's text response is discarded; the side effects (memory_tool
  # calls that write to the conversation's session memory list) are the point.
  @spec reflect(t) :: :ok
  def reflect(state) do
    UI.begin_step("Reflecting")

    # Snapshot the conversation state before the finalize completion can
    # mutate it. This gives the reflect agent a stable view of the session.
    msgs = Services.Conversation.get_messages(state.conversation_pid)
    session_memories = Services.Conversation.get_memory(state.conversation_pid)

    system_prompt = build_reflect_prompt(session_memories)
    filtered = filter_conversation_msgs(msgs)

    # The system prompt goes last so it isn't buried under a long conversation
    # context. The LLM sees the conversation first, then the directive.
    messages = filtered ++ [AI.Util.system_msg(system_prompt)]

    case AI.Completion.get(
           model: state.model,
           messages: messages,
           toolbox: %{"memory_tool" => AI.Tools.Memory},
           conversation_pid: state.conversation_pid,
           compact?: false,
           log_msgs: false,
           log_tool_calls: true
         ) do
      {:ok, _completion} ->
        :ok

      {:error, reason} ->
        UI.warn("Memory reflection failed", inspect(reason))
        :ok
    end
  end

  # Assemble the system prompt for the reflection completion. Includes the
  # full memory guidance, the reflection directive, and a listing of any
  # session memories already saved (to reduce redundant saves on --follow).
  defp build_reflect_prompt(session_memories) do
    parts = [@reflect_prompt, @reflect_directive]

    parts =
      case format_existing_memories(session_memories) do
        nil -> parts
        listing -> parts ++ [listing]
      end

    Enum.join(parts, "\n\n")
  end

  # Format session memories into a listing the reflect agent can reference to
  # avoid saving duplicates. Returns nil when there are no existing memories.
  @memory_preview_limit 120
  defp format_existing_memories([]), do: nil

  defp format_existing_memories(memories) do
    items =
      memories
      |> Enum.map(fn %Memory{title: title, content: content} ->
        preview = Util.truncate(content, @memory_preview_limit)
        "- #{title}: #{preview}"
      end)
      |> Enum.join("\n")

    """
    ### Already recorded this session
    #{items}

    Do not re-record information already captured above. Focus on NEW learnings.
    """
  end

  # Keep only user and assistant content messages. Drop system/developer
  # scaffolding, tool call requests, and tool responses -- the reflect agent
  # doesn't need them and they bloat the context.
  defp filter_conversation_msgs(msgs) do
    Enum.filter(msgs, fn
      %{role: "user"} -> true
      %{role: "assistant", content: content} when is_binary(content) -> true
      _ -> false
    end)
  end
end
