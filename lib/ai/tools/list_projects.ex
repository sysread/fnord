defmodule AI.Tools.ListProjects do
  @moduledoc """
  Lists all available projects except for the current project.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(_) do
    {"Listing projects", "Listing other projects"}
  end

  @impl AI.Tools
  # `result` here is what AI.Tools.perform_tool_call/3 returns to the caller -
  # a JSON-encoded string for structured (list/map) return values from `call/1`,
  # not the raw list. Decode-then-count keeps this resilient to that contract.
  def ui_note_on_result(_args, result) do
    count =
      case SafeJson.decode(result) do
        {:ok, list} when is_list(list) -> length(list)
        _ -> 0
      end

    {"Projects listed", "Found #{count} other project(s)"}
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      name: "list_projects_tool",
      description: "Lists all other available projects, apart from the currently active one.",
      parameters: %{
        type: "object",
        required: [],
        properties: %{}
      }
    }
  end

  @impl AI.Tools
  def call(_args) do
    settings = Settings.new()
    all_projects = Settings.list_projects(settings)

    current_project =
      case Settings.get_selected_project() do
        {:ok, project} -> project
        _ -> nil
      end

    filtered =
      if current_project do
        Enum.reject(all_projects, &(&1 == current_project))
      else
        all_projects
      end

    {:ok, filtered}
  end
end
