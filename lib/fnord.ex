defmodule Fnord do
  @moduledoc """
  Fnord is a code search tool that uses OpenAI's embeddings API to index and
  search code files.
  """

  @doc """
  Main entry point for the application. Parses command line arguments and
  dispatches to the appropriate subcommand.
  """
  def main(args) do
    with {:ok, subcommand, opts} <- parse_options(args) do
      case subcommand do
        :index -> Indexer.new(opts) |> Indexer.run()
        :search -> Search.run(opts)
        :summary -> Summary.run(opts)
        :torch -> Indexer.new(opts) |> Indexer.delete_project()
        :projects -> Store.list_projects() |> Enum.each(&IO.puts(&1))
        :files -> Store.new(opts.project) |> Store.list_files() |> Enum.each(&IO.puts(&1))
        :ask -> Ask.run(opts)
      end
    else
      {:error, reason} -> IO.puts("Error: #{reason}")
    end
  end

  defp parse_options(args) do
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
      default: false
    ]

    quiet = [
      long: "--quiet",
      short: "-q",
      help: "Suppress interactive output",
      required: false
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
      default: false
    ]

    file = [
      value_name: "FILE",
      long: "--file",
      short: "-f",
      help: "File to summarize",
      required: true
    ]

    concurrency = [
      value_name: "CONCURRENCY",
      long: "--concurrency",
      short: "-c",
      help: "Number of concurrent threads to use",
      parser: :integer,
      default: 4
    ]

    question = [
      value_name: "QUESTION",
      long: "--question",
      short: "-q",
      help: "The prompt to ask the AI",
      required: true
    ]

    relpath = [
      long: "--relpath",
      short: "-r",
      help: "Print paths relative to $CWD",
      default: false
    ]

    parser =
      Optimus.new!(
        name: "fnord",
        description: "fnord - intelligent code index and search",
        about: "Index and search code files",
        allow_unknown_args: false,
        version: get_version(),
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
            ],
            flags: [
              relpath: relpath
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
              project: project,
              concurrency: concurrency
            ],
            flags: [
              reindex: reindex,
              quiet: quiet
            ]
          ],
          search: [
            name: "search",
            about: "Search in the project",
            options: [
              project: project,
              query: query,
              limit: limit,
              concurrency: concurrency
            ],
            flags: [
              detail: detail
            ]
          ],
          summary: [
            name: "summary",
            about: "Get a summary of a file from the project index",
            options: [
              project: project,
              file: file
            ]
          ],
          ask: [
            name: "ask",
            about: "Conversational interface to the project database",
            options: [
              concurrency: concurrency
            ],
            args: [
              project: project,
              question: question
            ]
          ]
        ]
      )

    with {[subcommand], result} <- Optimus.parse!(parser, args) do
      options =
        result.args
        |> Map.merge(result.options)
        |> Map.merge(result.flags)
        |> maybe_override_quiet()

      {:ok, subcommand, options}
    else
      _ -> {:error, "missing or unknown subcommand"}
    end
  end

  defp get_version do
    {:ok, vsn} = :application.get_key(:fnord, :vsn)
    to_string(vsn)
  end

  # Overrides the --quiet flag if it was not already specified by the user and
  # the escript is not connected to a tty.
  defp maybe_override_quiet(opts) do
    cond do
      opts[:quiet] -> opts
      IO.ANSI.enabled?() -> opts
      true -> Map.put(opts, :quiet, true)
    end
  end
end
