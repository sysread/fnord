defmodule AI.Agent.Nomenclater do
  defmodule UniqueNameThing do
    def start() do
      case Process.whereis(__MODULE__) do
        nil -> Agent.start_link(&MapSet.new/0, name: __MODULE__)
        pid when is_pid(pid) -> {:ok, pid}
      end
    end

    def add_name(name) do
      Agent.update(__MODULE__, &MapSet.put(&1, name))
    end

    def existing_names() do
      Agent.get(__MODULE__, &MapSet.to_list/1)
    end
  end

  @max_attempts 3

  @model AI.Model.fast()

  @prompt """
  You are an AI agent within a larger system.
  Your only task is to provide a first name for other AI agents so that their actions can be clearly distinguished in the logs.
  Select a first name that is unique and not already used by another agent.
  Selecting fun, whimsical names is encouraged, so long as they are not vulgar or offensive.
  Your audience is geeky, so sci-fi- and cartoon-sounding names are welcome, but obviously not required.
  If every name sounded like a widget from Zork!, no one will complain!
  Try not to select names that are too similar to existing names, as that can cause confusion.
  Respond ONLY with the first name, without any additional text, explanation, or formatting.
  """
  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(_opts), do: get_name()

  defp get_name(attempt \\ 1)

  defp get_name(attempt) when attempt > @max_attempts do
    {:error, "Failed to generate a unique name after #{@max_attempts} attempts."}
  end

  defp get_name(attempt) do
    with {:ok, _pid} <- UniqueNameThing.start() do
      names =
        UniqueNameThing.existing_names()
        |> Enum.map(&"- #{&1}")
        |> Enum.join("\n")

      warning =
        if attempt > 1 do
          ""
        else
          """
          **Warning:**
          Your previous response contained more than one word, which is not allowed.
          Please provide a single-word first name for an AI agent.
          """
        end

      AI.Completion.get(
        model: @model,
        messages: [
          AI.Util.system_msg(@prompt),
          AI.Util.user_msg("""
          #{warning}

          These names are already in use:
          #{names}

          Please provide a unique first name for an AI agent.
          """)
        ]
      )
      |> case do
        {:ok, %{response: response}} ->
          # Quickly check that it's just a one-word response as a half-assed
          # heuristic for validation.
          if Regex.match?(~r/^\w+$/, response) do
            UniqueNameThing.add_name(response)
            {:ok, response}
          else
            get_name(attempt + 1)
          end

        {:error, %{response: response}} ->
          {:error, response}
      end
    end
  end
end
