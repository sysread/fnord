defmodule Fnord do
  @moduledoc """
  Fnord is a code search tool that uses OpenAI's embeddings API to index and
  search code files.
  """

  require Logger

  @default_concurrency 4
  @default_search_limit 10

  @doc """
  Main entry point for the application. Parses command line arguments and
  dispatches to the appropriate subcommand.
  """
  def main(args) do
    {:ok, _} = Application.ensure_all_started(:briefly)

    configure_logger()

    with {:ok, subcommand, opts} <- parse_options(args) do
      set_globals(opts)

      case subcommand do
        :index -> Cmd.Indexer.new(opts) |> Cmd.Indexer.run()
        :search -> Cmd.Search.run(opts)
        :summary -> Cmd.Summary.run(opts)
        :torch -> Cmd.Torch.run(opts)
        :projects -> Cmd.Projects.run(opts)
        :files -> Cmd.Files.run(opts)
        :ask -> Cmd.Ask.run(opts)
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
      help:
        "Directory to index (required only for first index or reindex after moving the project directory)",
      required: false
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
      default: @default_search_limit
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
      default: @default_concurrency
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

  def configure_logger do
    {:ok, handler_config} = :logger.get_handler_config(:default)
    updated_config = Map.update!(handler_config, :config, &Map.put(&1, :type, :standard_error))

    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, updated_config)

    :ok =
      :logger.update_formatter_config(
        :default,
        :template,
        ["[", :level, "] ", :message, "\n"]
      )

    :ok = :logger.set_primary_config(:level, :info)
  end

  defp set_globals(args) do
    args
    |> Enum.each(fn
      {:concurrency, concurrency} -> Application.put_env(:fnord, :concurrency, concurrency)
      {:project, project} -> Application.put_env(:fnord, :project, project)
      {:quiet, quiet} -> Application.put_env(:fnord, :quiet, quiet)
      _ -> :ok
    end)
  end
end
