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
  def run(opts, _subcommands, _unknown) do
    with {:ok, project} <- Store.get_project() do
      project
      |> Store.Project.stored_files()
      |> Enum.map(fn entry ->
        if opts[:relpath] do
          Path.relative_to(entry.file, project.source_root)
        else
          entry.rel_path
        end
      end)
      |> Enum.sort()
      |> Enum.each(&UI.puts/1)
    end
  end
end
