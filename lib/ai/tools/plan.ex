defmodule AI.Tools.Plan do
  @moduledoc """
  Read-only Plan tool for inspecting project plans stored in the fnord project store.

  This initial version exposes a `plan_get` operation that returns either the
  entire plan or a specific section for a given `plan_name`. Mutating
  operations (set_meta, set_design, etc.) will be added in later steps.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args) do
    {:ok, args}
  end

  @impl AI.Tools
  def ui_note_on_request(_args), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "plan_tool",
        description:
          "Read-only access to a project plan stored in the fnord project store.",
        parameters: %{
          type: "object",
          required: ["plan_name"],
          properties: %{
            "plan_name" => %{
              type: "string",
              description: "Name of the plan to inspect"
            },
            "section" => %{
              type: "string",
              enum: ["meta", "design", "implementation", "decisions", "work_log"],
              description:
                "Optional section of the plan to return; if omitted, the full plan is returned"
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"plan_name" => plan_name} = args) do
    section = Map.get(args, "section", nil)

    with {:ok, project} <- Store.get_project(),
         path <- Store.Project.Plan.plan_path(project, plan_name),
         {:ok, plan} <- Store.Project.Plan.read(path) do
      {:ok, select_section(plan, section)}
    else
      {:error, :enoent} ->
        {:error, :no_plan}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_section(plan, nil), do: plan

  defp select_section(plan, "meta"), do: plan.meta
  defp select_section(plan, "design"), do: plan.design
  defp select_section(plan, "implementation"), do: plan.implementation
  defp select_section(plan, "decisions"), do: plan.decisions
  defp select_section(plan, "work_log"), do: plan.work_log

  defp select_section(_plan, _unknown), do: nil
end
