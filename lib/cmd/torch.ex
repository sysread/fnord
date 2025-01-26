defmodule Cmd.Torch do
  @behaviour Cmd

  @impl Cmd
  def spec do
    [
      torch: [
        name: "torch",
        about: "Deletes a previously indexed project from the database",
        options: [
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  @doc """
  Permanently deletes the project from the store.
  """
  def run(_opts, _unknown) do
    Store.get_project()
    |> Store.Project.torch()
  end
end
