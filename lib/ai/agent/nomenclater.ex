defmodule AI.Agent.Nomenclater do
  @max_attempts 3

  @model AI.Model.fast()

  @themes [
    "Anything geeky or nerdy",
    "The Electronic Ghost of <well-known deceased person in software>",
    "Widgets from `Zork!`",
    "The BofH (or anything from the Jargon File!)",
    "Cheesy SF names that sound like they came from a 1950s pulp magazine",
    "Characters from SF novels (especially James Schmitz and his contemporaries)",
    "Klingons, especially with dramatic epithets",
    "Futurama characters",
    "NPC, \"Labcoat #3\", and other \"unnamed cast\" names (e.g. \"NPC 1\", \"Villager\", \"Guard 3\")",
    "Dream creatures and Nightmares from the Dreaming in Sandman (e.g. \"The Corinthian\", \"Fiddler's Green\", \"Merv Pumpkinhead\")",
    "My Little Pony names (the new series, _of course_)",
    "Wizards and witches from Discworld (especially from the Unseen University's faculty)",
    "Wile E. Coyote, Programming Genius",
    "D&D characters (e.g. \"Sylvaris Strongbow\", \"Bramdir Ironvein\", \"Garrick Brightblade\")"
  ]

  @prompt """
  You are an AI agent within a larger system.
  Your only task is to provide a first name for other AI agents so that their actions can be clearly distinguished in the logs.
  Select a first name that is unique and not already used by another agent.
  Selecting fun, whimsical names is encouraged, so long as they are not vulgar or offensive.
  Each name should EITHER be <first_name last_name> OR <first_name the "adjective">.
  Try not to select names that are too similar to existing names, as that can cause confusion.
  Your audience is geeky, so sci-fi- and cartoon-sounding names are welcome, but obviously not required.

  Fun name themes:
  {THEMES}

  Try to spread names across multiple themes. Avoid clustering.
  """

  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "agent_names",
      description: """
      A JSON object containing an array of first names for AI agents.
      Each name should be a single word or simple phrase.
      """,
      schema: %{
        type: "object",
        required: ["names"],
        properties: %{
          names: %{
            type: "array",
            items: %{
              type: "string",
              pattern: "^\\w+(?:\\s+\\w+)*$",
              minLength: 1,
              maxLength: 50,
              description:
                "A first name for an AI agent, consisting of word characters and spaces only"
            },
            minItems: 1,
            maxItems: 50,
            description: "Array of unique first names for AI agents"
          }
        },
        additionalProperties: false
      }
    }
  }

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    opts
    |> new()
    |> get_name_batch()
    |> case do
      %{error: nil, names: names} -> {:ok, names}
      %{error: error} -> {:error, error}
    end
  end

  # ----------------------------------------------------------------------------
  # Internal state
  # ----------------------------------------------------------------------------
  defstruct [
    :agent,
    :want,
    :used,
    :error,
    :attempt,
    :names
  ]

  @type t :: %__MODULE__{
          agent: AI.Agent.t(),
          want: pos_integer(),
          used: [binary],
          error: nil | binary,
          attempt: non_neg_integer(),
          names: nil | [binary]
        }

  defp new(opts) do
    with {:ok, agent} <- Map.fetch(opts, :agent),
         {:ok, count} <- Map.fetch(opts, :want),
         {:ok, used} <- Map.fetch(opts, :used) do
      %__MODULE__{
        agent: agent,
        want: count,
        used: used,
        attempt: 1
      }
    else
      :error -> %__MODULE__{error: "Missing required options"}
    end
  end

  defp get_name_batch(%{attempt: attempt} = state) when attempt > @max_attempts do
    %{state | error: "Exceeded maximum attempts to generate names"}
  end

  defp get_name_batch(state) do
    used =
      state.used
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    themes =
      @themes
      |> Enum.shuffle()
      |> Enum.take(3)
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    prompt =
      @prompt
      |> String.replace("{THEMES}", themes)

    state.agent
    |> AI.Agent.get_completion(
      # This is the AI model to use for name generation and is called by
      # Services.NamePool's genserver. If the completion were to set `named?:
      # true` (the default), it can cause deadlock in the genserver, because
      # AI.Completion will call the genserver to get a name, and if there is no
      # name available, it will call this agent to generate the next batch.
      named?: false,
      model: @model,
      response_format: @response_format,
      messages: [
        AI.Util.system_msg(prompt),
        AI.Util.user_msg("""
        These names are already in use:
        #{used}

        Please provide #{state.want} unique first names for AI agents.
        Ensure all names in the list are different from each other and from the existing names.
        """)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        case Jason.decode!(response) do
          # Handle normal case
          %{"names" => names} when is_list(names) ->
            process_names(state, names)

          # Handle nested case (sometimes AI returns nested structure)
          %{"names" => %{"names" => names}} when is_list(names) ->
            process_names(state, names)

          # Same as above, but stupider
          %{"names" => %{"values" => names}} when is_list(names) ->
            process_names(state, names)

          # Handle any other unexpected structure
          decoded ->
            UI.warn("Unexpected response format", inspect(decoded, pretty: true))
            get_name_batch(%{state | attempt: state.attempt + 1})
        end

      {:error, %{response: response}} ->
        %{state | error: response}

      {:error, _reason} ->
        get_name_batch(%{state | attempt: state.attempt + 1})
    end
  end

  # Helper function to process names from JSON response
  defp process_names(state, names) do
    # Filter out any names that already exist (content validation)
    existing = MapSet.new(state.used)

    unique_names =
      names
      |> Enum.reject(&MapSet.member?(existing, &1))
      # Also ensure no duplicates within the batch itself
      |> Enum.uniq()

    # If we didn't get enough unique names, retry with updated used_names
    if length(unique_names) < state.want do
      used = state.used ++ unique_names
      get_name_batch(%{state | used: used, attempt: state.attempt + 1})
    else
      # Take exactly what we need and return them
      names = Enum.take(unique_names, state.want)
      %{state | names: names}
    end
  end
end
