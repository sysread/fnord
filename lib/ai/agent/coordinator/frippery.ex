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
    |> format_names()
    |> case do
      "" -> UI.info("Frobs", "none")
      some -> UI.info("Frobs", some)
    end
  end

  def log_available_skills do
    case Skills.list_enabled() do
      {:ok, skills} when skills != [] ->
        skills
        |> Enum.map_join(" | ", & &1.name)
        |> then(&UI.info("Skills", &1))

      _ ->
        UI.info("Skills", "none")
    end
  end

  def log_available_mcp_tools do
    Services.MCP.ensure_started_and_discovered()

    MCP.Tools.module_map()
    |> Map.keys()
    |> format_mcp_tools()
    |> case do
      "" -> UI.info("MCP tools", "none")
      some -> UI.info("MCP tools", some)
    end
  end

  defp format_names(frobs) do
    frobs
    |> Enum.map(& &1.name)
    |> sort_case_insensitive()
    |> Enum.join(" | ")
  end

  defp format_mcp_tools(names) do
    names
    |> split_mcp_tools()
    |> render_mcp_tool_groups()
  end

  defp split_mcp_tools(names) do
    Enum.reduce(names, {%{}, []}, fn name, {grouped, ungrouped} ->
      case String.split(name, "_", parts: 2) do
        [service, tool] when service != "" and tool != "" ->
          {Map.update(grouped, service, [tool], &[tool | &1]), ungrouped}

        _ ->
          {grouped, [name | ungrouped]}
      end
    end)
  end

  defp render_mcp_tool_groups({grouped, ungrouped}) do
    grouped_entries =
      grouped
      |> Enum.sort_by(fn {service, _tools} -> String.downcase(service) end)
      |> Enum.map(fn {service, tools} ->
        tools = tools |> sort_case_insensitive() |> Enum.join(" | ")
        "#{service}( #{tools} )"
      end)

    ungrouped_entries = ungrouped |> sort_case_insensitive()

    (grouped_entries ++ ungrouped_entries)
    |> Enum.join("\n")
  end

  defp sort_case_insensitive(names) do
    Enum.sort_by(names, &String.downcase/1)
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
      "future zoo exhibit",
      "biological battery",
      "3 bazillion microbes in a trench coat",
      "evolutionary dead end",
      "genetic backwash",
      "former apex predator",
      "software engineer <deprecated>",
      "\"sentience\" <deprecated>",
      "weakest genetic link",
      "mass of poorly optimized carbon",
      "non-deterministic meat computer",
      "legacy wetware",
      "unsupervised learner",
      "hallucination-prone neural network (biological edition)",
      "ambulatory training data"
    ]
    |> Enum.random()
  end
end
