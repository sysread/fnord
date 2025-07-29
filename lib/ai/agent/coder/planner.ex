defmodule AI.Agent.Coder.Planner do
  @moduledoc """
  Agent for planning coding tasks.

  Given an instruction, outputs a JSON array of strings,
  each describing a step to implement the requested changes.
  """

  @behaviour AI.Agent

  @model AI.Model.balanced()

  @prompt """
  You are a planning agent. Given a user instruction, output strictly a JSON
  array of strings representing each step to implement the requested changes.
  No additional text.
  """

  @type params() :: %{required(:instruction) => String.t()}
  @type list_id() :: any()
  @type reason() :: String.t()

  @max_attempts 3
  @toolbox AI.Tools.all_tools()
           |> Map.drop(["file_edit_tool", "file_manage_tool"])
           |> Enum.filter(fn {k, _v} -> not String.contains?(k, ["edit", "manage"]) end)
           |> Map.new()

  @impl AI.Agent
  @spec get_response(params()) :: {:ok, list_id()} | {:error, reason()}
  def get_response(%{instruction: instruction}) when is_binary(instruction) do
    do_plan(instruction, @max_attempts)
  end

  def get_response(_), do: {:error, "invalid parameters"}

  defp do_plan(_instruction, 0) do
    {:error, "failed to parse JSON plan after #{@max_attempts} attempts"}
  end

  defp do_plan(instruction, attempts_left) do
    prompt = [
      %{role: "system", content: @prompt},
      %{role: "user", content: instruction}
    ]

    case AI.Completion.get(model: @model, toolbox: @toolbox, messages: prompt) do
      {:ok, %AI.Completion{response: content}} ->
        with {:ok, steps} when is_list(steps) <- Jason.decode(content),
             true <- Enum.all?(steps, &is_binary/1) do
          list_id = TaskServer.start_list()
          Enum.each(steps, &TaskServer.add_task(list_id, &1))
          {:ok, list_id}
        else
          _ -> do_plan(instruction, attempts_left - 1)
        end

      {:error, reason} ->
        {:error, "completion error: #{inspect(reason)}"}
    end
  end
end
