defmodule Fnord do
  defstruct [:project, :store, :scanner, :ai]

  @fnord_home "#{System.get_env("HOME")}/.fnord"
  @storage_dir "#{@fnord_home}/storage"

  def main(args) do
    with {:ok, subcommand, opts} <- parse_options(args),
         :ok <- init_env() do
      app = %Fnord{
        project: opts.project,
        store: Store.new(@storage_dir, opts.project),
        ai: AI.new()
      }

      case subcommand do
        :index -> Index.run(app, opts.directory)
        :search -> Search.run(app, opts.query)
      end
    end
  end

  def init_env() do
    with :ok <- File.mkdir_p!(@fnord_home),
         :ok <- File.mkdir_p!(@storage_dir) do
      :ok
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
      long: "--directory",
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
          list_projects: [
            name: "list-projects",
            about: "List all projects",
            options: [
              project: project
            ]
          ],
          list_files: [
            name: "list-files",
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
