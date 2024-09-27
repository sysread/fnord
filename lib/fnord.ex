defmodule Fnord do
  def main(args) do
    with {:ok, subcommand, opts} <- parse_options(args) do
      case subcommand do
        :index -> Index.run(opts.directory, opts.project)
        :search -> Search.run(opts.project, opts.query)
        :files -> Store.new(opts.project) |> Store.list_files() |> Enum.each(&IO.puts(&1))
        :projects -> Store.list_projects() |> Enum.each(&IO.puts(&1))
      end
    end
  end

  def parse_options(args) do
    project = [
      value_name: "PROJECT",
      long: "--project",
      short: "-p",
      help: "Project name",
      required: true
    ]

    directory = [
      value_name: "DIR",
      long: "--dir",
      short: "-d",
      help: "Directory to index",
      required: true
    ]

    query = [
      value_name: "QUERY",
      long: "--query",
      short: "-q",
      help: "Search query",
      required: true
    ]

    parser =
      Optimus.new!(
        name: "fnord",
        description: "intelligent code search",
        version: "1.0.0",
        author: "Jeff Ober",
        about: "Index and search code files",
        allow_unknown_args: false,
        subcommands: [
          index: [
            name: "index",
            about: "Index the directory",
            options: [
              directory: directory,
              project: project
            ]
          ],
          projects: [
            name: "projects",
            about: "List all projects",
            options: []
          ],
          files: [
            name: "files",
            about: "List files in a project",
            options: [
              project: project
            ]
          ],
          search: [
            name: "search",
            about: "Search in the project",
            options: [
              project: project,
              query: query
            ]
          ]
        ]
      )

    {[subcommand], %{options: opts}} = Optimus.parse!(parser, args)

    {:ok, subcommand, opts}
  end
end
