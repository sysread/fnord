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
  def ui_note_on_request(_args), do: "plan_tool: inspecting plan"

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: "plan_tool: finished"

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: "plan_tool failed"

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "plan_tool",
        description:
          "Read-only access to a project plan stored in the fnord project store. When `meta_delta` is provided, the tool will merge the given metadata into the plan's meta section. When `design_content` is provided, the tool will update the plan's design section with the given content.",
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
            },
            "meta_delta" => %{
              type: "object",
              description: "Map of metadata keys to merge into the plan's meta section"
            },
            "design_content" => %{
              type: "string",
              description: "Design content to merge into the plan's design section"
            },
            "design_format" => %{
              type: "string",
              description: "Format of the design content, e.g. markdown"
            },
            "implementation" => %{
              type: "object",
              description: "Implementation plan (milestones list) to store in the plan"
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"plan_name" => plan_name, "meta_delta" => meta_delta}) do
    plan_set_meta(plan_name, meta_delta)
  end

  @impl AI.Tools
  def call(%{"plan_name" => plan_name, "implementation" => implementation_map}) do
    plan_set_implementation(plan_name, implementation_map)
  end

  @impl AI.Tools
  def call(%{"plan_name" => plan_name, "design_content" => content} = args) do
    format = Map.get(args, "design_format", "markdown")
    plan_set_design(plan_name, content, format)
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

  defp plan_set_meta(plan_name, meta_delta) do
    case Store.get_project() do
      {:ok, project} ->
        path = Store.Project.Plan.plan_path(project, plan_name)

        plan_or_error =
          case Store.Project.Plan.read(path) do
            {:ok, plan} -> plan
            {:error, :enoent} -> %Store.Project.Plan{meta: %{}}
            {:error, reason} -> {:error, reason}
          end

        case plan_or_error do
          {:error, reason} ->
            {:error, reason}

          plan ->
            new_meta =
              plan.meta
              |> Map.merge(meta_delta)
              |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

            updated_plan = %Store.Project.Plan{plan | meta: new_meta}

            case Store.Project.Plan.write(path, updated_plan) do
              :ok -> {:ok, updated_plan}
              {:error, reason} -> {:error, reason}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp plan_set_design(plan_name, content, format) do
    case Store.get_project() do
      {:ok, project} ->
        path = Store.Project.Plan.plan_path(project, plan_name)

        plan_or_error =
          case Store.Project.Plan.read(path) do
            {:ok, plan} -> plan
            {:error, :enoent} -> %Store.Project.Plan{meta: %{}, design: nil}
            {:error, reason} -> {:error, reason}
          end

        case plan_or_error do
          {:error, reason} ->
            {:error, reason}

          plan ->
            new_design = %{"format" => format, "content" => content}

            new_meta =
              plan.meta
              |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

            updated_plan =
              %Store.Project.Plan{plan | design: new_design, meta: new_meta}

            case Store.Project.Plan.write(path, updated_plan) do
              :ok -> {:ok, updated_plan}
              {:error, reason} -> {:error, reason}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_implementation(%{"milestones" => milestones}) when is_list(milestones) do
    if Enum.all?(milestones, &valid_milestone?/1) do
      :ok
    else
      {:error, :invalid_milestones}
    end
  end

  defp validate_implementation(_), do: {:error, :invalid_implementation}

  defp valid_milestone?(m) when is_map(m) do
    Map.has_key?(m, "id") and
      Map.has_key?(m, "title") and
      Map.has_key?(m, "status") and
      Map.has_key?(m, "steps")
  end

  defp valid_milestone?(_), do: false

  defp plan_set_implementation(plan_name, implementation_map) do
    case Store.get_project() do
      {:ok, project} ->
        path = Store.Project.Plan.plan_path(project, plan_name)

        plan_or_error =
          case Store.Project.Plan.read(path) do
            {:ok, plan} -> plan
            {:error, :enoent} -> %Store.Project.Plan{meta: %{}, implementation: nil}
            {:error, reason} -> {:error, reason}
          end

        case plan_or_error do
          {:error, reason} ->
            {:error, reason}

          plan ->
            with :ok <- validate_implementation(implementation_map) do
              new_meta =
                plan.meta
                |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

              updated_plan =
                %Store.Project.Plan{plan | implementation: implementation_map, meta: new_meta}

              case Store.Project.Plan.write(path, updated_plan) do
                :ok -> {:ok, updated_plan}
                {:error, reason} -> {:error, reason}
              end
            else
              {:error, reason} -> {:error, reason}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
