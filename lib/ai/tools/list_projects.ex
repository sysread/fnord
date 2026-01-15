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
  def ui_note_on_result(_args, result) do
    {"Projects listed", "Found #{length(result)} other project(s)"}
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "list_projects_tool",
        description: "Lists all other available projects, apart from the currently active one.",
        parameters: %{
          type: "object",
          required: [],
          properties: %{}
        }
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
