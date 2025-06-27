defmodule Cmd.Torch do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec do
    [
      torch: [
        name: "torch",
        about: "Deletes a previously indexed project from the database",
        options: [
          project: Cmd.project_arg()
        ]
      ]
    ]
  end

  @impl Cmd
  @doc """
  Permanently deletes the project from the store.
  """
  def run(_opts, _subcommands, _unknown) do
    with {:ok, project} <- Store.get_project() do
      Store.Project.torch(project)
    end
  end
end
