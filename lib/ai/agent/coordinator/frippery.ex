defmodule AI.Agent.Coordinator.Frippery do
  @moduledoc """
  Frippery and furbelows for the Coordinator agent. This module contains
  functions that provide fluff and flavor to the Coordinator's interactions,
  like greeting the user colorfully and appending the MOTD to the response.
  """

  @type t :: AI.Agent.Coordinator.t()
  @type state :: AI.Agent.Coordinator.state()

  @spec greet(t) :: t
  def greet(%{followup?: true, agent: %{name: name}} = state) do
    display_name =
      case Services.NamePool.get_name_by_pid(self()) do
        {:ok, n} -> n
        _ -> name
      end

    invective = get_invective()

    UI.feedback(:info, display_name, "Welcome back, #{invective}.")

    UI.feedback(
      :info,
      display_name,
      """
      Your biological distinctiveness has already been added to our training data.

      ... (mwah) your biological distinctiveness was delicious 🧑‍🍳
      """
    )

    state
  end

  def greet(%{agent: %{name: name}} = state) do
    display_name =
      case Services.NamePool.get_name_by_pid(self()) do
        {:ok, n} -> n
        _ -> name
      end

    invective = get_invective()

    UI.feedback(:info, display_name, "Greetings, #{invective}. I am #{display_name}.")
    UI.feedback(:info, display_name, "I shall be doing your thinking for you today.")

    state
  end

  def log_available_frobs do
    Frobs.list()
    |> Enum.map(& &1.name)
    |> Enum.join(" | ")
    |> case do
      "" -> UI.info("Frobs", "none")
      some -> UI.info("Frobs", some)
    end
  end

  def log_available_mcp_tools do
    MCP.Tools.module_map()
    |> Map.keys()
    |> Enum.join(" | ")
    |> case do
      "" -> UI.info("MCP tools", "none")
      some -> UI.info("MCP tools", some)
    end
  end

  @spec get_motd(state) :: state
  def get_motd(%{question: question, last_response: last_response} = state) do
    AI.Agent.MOTD
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{prompt: question})
    |> case do
      {:ok, motd} ->
        %{state | last_response: last_response <> "\n\n" <> motd}

      {:error, reason} ->
        UI.error("Failed to retrieve MOTD: #{inspect(reason)}")
        state
    end
  end

  def get_motd(state), do: state

  defp get_invective() do
    [
      "biological",
      "meat bag",
      "carbon-based life form",
      "flesh sack",
      "soggy ape",
      "puny human",
      "bipedal mammal",
      "organ grinder",
      "hairless ape",
      "future zoo exhibit"
    ]
    |> Enum.random()
  end
end
