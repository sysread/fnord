defmodule Fnord do
  @moduledoc """
  Fnord is a code search tool that uses OpenAI's embeddings API to index and search code files.
  """

  def main(args) do
    with {:ok, subcommand, opts} <- parse_options(args) do
      case subcommand do
        :index -> Index.new(opts.project, opts.directory) |> Index.run(opts.reindex)
        :search -> Search.run(opts)
        :files -> Store.new(opts.project) |> Store.list_files() |> Enum.each(&IO.puts(&1))
        :projects -> Store.list_projects() |> Enum.each(&IO.puts(&1))
        :torch -> Index.delete_project(opts.project)
      end
    else
      {:error, reason} -> IO.puts("Error: #{reason}")
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

    reindex = [
      long: "--reindex",
      short: "-r",
      help: "Reindex the project",
      default: false,
      multiple: false
    ]

    query = [
      value_name: "QUERY",
      long: "--query",
      short: "-q",
      help: "Search query",
      required: true
    ]

    limit = [
      value_name: "LIMIT",
      long: "--limit",
      short: "-l",
      help: "Limit the number of results",
      default: 10
    ]

    detail = [
      long: "--detail",
      help: "Include AI-generated file summary",
      default: false,
      multiple: false
    ]

    parser =
      Optimus.new!(
        name: "fnord",
        description: "fnord - intelligent code index and search",
        about: "Index and search code files",
        allow_unknown_args: false,
        subcommands: [
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
          torch: [
            name: "torch",
            about: "Delete a previously indexed project from the database",
            options: [
              project: project
            ]
          ],
          index: [
            name: "index",
            about: "Index the directory",
            options: [
              directory: directory,
              project: project
            ],
            flags: [
              reindex: reindex
            ]
          ],
          search: [
            name: "search",
            about: "Search in the project",
            options: [
              project: project,
              query: query,
              limit: limit
            ],
            flags: [
              detail: detail
            ]
          ]
        ]
      )

    with {[subcommand], result} <- Optimus.parse!(parser, args) do
      options =
        result.args
        |> Map.merge(result.options)
        |> Map.merge(result.flags)

      {:ok, subcommand, options}
    else
      _ -> {:error, "missing or unknown subcommand"}
    end
  end
end
