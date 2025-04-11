defmodule Cmd.Files do
  @behaviour Cmd

  @impl Cmd
  def spec do
    [
      files: [
        name: "files",
        about: "Lists all indexed files in a project",
        options: [
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ]
        ],
        flags: [
          relpath: [
            long: "--relpath",
            short: "-r",
            help: "Print paths relative to $CWD",
            default: false
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(_opts, _subcommands, _unkown) do
    Store.get_project()
    |> Store.Project.stored_files()
    |> Stream.map(& &1.rel_path)
    |> Enum.sort()
    |> Enum.each(&IO.puts(&1))
  end
end
