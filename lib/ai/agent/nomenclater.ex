defmodule AI.Agent.Nomenclater do
  @max_attempts 3

  @model AI.Model.fast()

  @prompt """
  You are an AI agent within a larger system.
  Your only task is to provide a first name for other AI agents so that their actions can be clearly distinguished in the logs.
  Select a first name that is unique and not already used by another agent.
  Selecting fun, whimsical names is encouraged, so long as they are not vulgar or offensive.
  Each name should EITHER be <first_name last_name> OR <first_name the "adjective">.
  Try not to select names that are too similar to existing names, as that can cause confusion.
  Your audience is geeky, so sci-fi- and cartoon-sounding names are welcome, but obviously not required.

  Fun name themes:
  - Klingons, especially with dramatic epithets
  - NPC, "Labcoat #3", and other "unnamed cast" names (e.g. "NPC 1", "Villager", "Guard 3")
  - The Electronic Ghost of <well-known deceased person in software>
  - Widgets from `Zork!`
  - Characters from SF novels (especially James Schmitz and his contemporaries)
  - My Little Pony names (the new series, _of course_)
  - D&D characters (e.g. "Sylvaris Strongbow", "Bramdir Ironvein", "Garrick Brightblade")

  Try to spread names across different themes.
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
  def get_response(_opts) do
    # Use batch system with count of 1 for compatibility
    # No used names context available at this level
    case get_names(1, []) do
      {:ok, [name]} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets a batch of unique names efficiently. This is the primary interface for
  name generation, used by the Services.NamePool.

  ## Parameters
  - count: Number of names to generate
  - used_names: List of names already in use (defaults to empty list)
  """
  @spec get_names(pos_integer(), [String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def get_names(count, used_names \\ [])
      when is_integer(count) and count > 0 and is_list(used_names) do
    get_name_batch(count, used_names)
  end

  defp get_name_batch(count, used_names, attempt \\ 1)

  defp get_name_batch(count, _used_names, attempt) when attempt > @max_attempts do
    {:error, "Failed to generate #{count} unique names after #{@max_attempts} attempts."}
  end

  defp get_name_batch(count, used_names, attempt) do
    existing_names =
      used_names
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    AI.Completion.get(
      model: @model,
      response_format: @response_format,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg("""
        These names are already in use:
        #{existing_names}

        Please provide #{count} unique first names for AI agents.
        Ensure all names in the list are different from each other and from the existing names.
        """)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        case Jason.decode!(response) do
          # Handle normal case
          %{"names" => names} when is_list(names) ->
            process_names(names, count, used_names, attempt)

          # Handle nested case (sometimes AI returns nested structure)
          %{"names" => %{"names" => names}} when is_list(names) ->
            process_names(names, count, used_names, attempt)

          # Handle any other unexpected structure
          decoded ->
            {:error, "Unexpected response format: #{inspect(decoded)}"}
        end

      {:error, %{response: response}} ->
        {:error, response}

      {:error, _reason} ->
        get_name_batch(count, used_names, attempt + 1)
    end
  end

  # Helper function to process names from JSON response
  defp process_names(names, count, used_names, attempt) do
    # Filter out any names that already exist (content validation)
    existing = MapSet.new(used_names)

    unique_names =
      names
      |> Enum.reject(&MapSet.member?(existing, &1))
      # Also ensure no duplicates within the batch itself
      |> Enum.uniq()

    # If we didn't get enough unique names, retry with updated used_names
    if length(unique_names) < count do
      updated_used_names = used_names ++ unique_names
      get_name_batch(count - length(unique_names), updated_used_names, attempt + 1)
    else
      # Take exactly what we need and return them
      final_names = Enum.take(unique_names, count)
      {:ok, final_names}
    end
  end
end
