defmodule AI.Agent.Coordinator.Memory do
  @moduledoc """
  Functions related to the Coordinator's memory behavior: prompt text,
  identity injection at session start, and semantic memory recall.
  """

  @type t :: AI.Agent.Coordinator.t()
  @type state :: AI.Agent.Coordinator.state()

  @memory_recall_limit 3
  @memory_size_limit 1000
  @recall_scopes [:global, :project]

  @prompt """
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
    - "shell_tool has `&&` operator to execute commands progressively"
    - "coder_tool sucks without clear code anchors"
    - "coder_tool sometimes fails to format code correctly; **check formatting and syntax after using it**"
    - "user prefers concise answers and hates hand-holding"
    - "user requires more detail about frontend than backend"
    - "user requires more hand-holding with infrastructure than with complex code"
    - "user appreciates task list summary and clear log of decision-chain"
    - "I can test hypotheses by writing (and cleaning up) scripts in the project directory; I do not have direct access to /tmp, but scripts can write to /tmp"
  """

  @spec prompt() :: binary
  def prompt, do: @prompt

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
      |> Enum.map(fn {mem, _score} -> format_recalled_memory(mem, now) end)
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
end
