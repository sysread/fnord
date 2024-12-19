defmodule Store do
  require Logger

  def store_home() do
    home = Settings.home()
    File.mkdir_p!(home)
    home
  end

  def get_project(nil), do: get_project()

  def get_project(project_name) do
    home = store_home()
    store_path = Path.join(home, project_name)
    Store.Project.new(project_name, store_path)
  end

  def get_project() do
    project = Settings.get_selected_project!()
    get_project(project)
  end

  def list_projects() do
    home = Settings.home()

    home
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.basename/1)
    |> Enum.map(&Store.Project.new(&1, home))
  end

  def list_conversations() do
    get_project()
    |> Store.Project.conversations()
    |> Enum.sort(fn a, b ->
      Store.Conversation.timestamp(a) > Store.Conversation.timestamp(b)
    end)
  end
end
