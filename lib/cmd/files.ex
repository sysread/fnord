defmodule Cmd.Files do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec do
    [
      files: [
        name: "files",
        about: "Lists all indexed files in a project",
        flags: [
          relpath: [
            long: "--relpath",
            short: "-r",
            help: "Print paths relative to $CWD",
            default: false
          ]
        ],
        options: [
          project: Cmd.project_arg()
        ]
      ]
    ]
  end

  @impl Cmd
  def run(_opts, _subcommands, _unknown) do
    with {:ok, project} <- Store.get_project() do
      project
      |> Store.Project.stored_files()
      |> Stream.map(& &1.rel_path)
      |> Enum.sort()
      |> Enum.each(&IO.puts(&1))
    end
  end
end
