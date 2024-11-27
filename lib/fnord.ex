defmodule Fnord do
  @moduledoc """
  Fnord is a code search tool that uses OpenAI's embeddings API to index and
  search code files.
  """

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
        :ask -> Cmd.Ask.run(opts)
        :search -> Cmd.Search.run(opts)
        :summary -> Cmd.Summary.run(opts)
        :torch -> Cmd.Torch.run(opts)
        :projects -> Cmd.Projects.run(opts)
        :files -> Cmd.Files.run(opts)
        :upgrade -> Cmd.Upgrade.run(opts)
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
      help: "Directory to index (required for first index or reindex after moving the project)",
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
      help: "Suppress interactive output; automatically enabled when executed in a pipe",
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
      value_name: "WORKERS",
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

    yes = [
      long: "--yes",
      short: "-y",
      help: "Automatically answer 'yes' to all prompts",
      default: false
    ]

    include = [
      value_name: "FILE",
      long: "--include",
      short: "-i",
      help: "Include a file in your prompt",
      multiple: true
    ]

    exclude = [
      value_name: "FILE",
      long: "--exclude",
      short: "-x",
      help: "Exclude a file from being indexed",
      multiple: true
    ]

    parser =
      Optimus.new!(
        name: "fnord",
        description: "fnord - intelligent code index and search",
        about: """

        | SYNOPSIS

        fnord is a code search tool and on-demand wiki for your code base. It
        uses OpenAI's API to generated embeddings and summaries of all text
        files in your project. You can then perform semantic searches against
        your code base or ask the AI questions about your code.

        | INDEXING A PROJECT

        Index a project for the first time or after moving the project
        directory. You must specify the project name and the directory to
        index. The directory is only required for the first index or after
        moving the project directory.

        The first time you run this, it will take a while, but subseuqent runs
        will only index new or changed files, and will delete files that no
        longer exist in the project directory. You can override this behavior
        and force a full reindex with the --reindex flag.

        You can control the number of concurrent API requests with the
        --concurrency flag. The default is 4.

          $ fnord index --project my_project --dir /path/to/my_project --concurrency 8

        | SEMANTIC SEARCH

          $ fnord search --project my_project --query "web service api routes"

        | CONVERSATIONAL INTERFACE

        Note the shorthand syntax for the project and question. The AI
        assistant may make multiple API requests as it uses the tools provided
        by fnord to perform research tasks within the project.

          $ fnord ask my_project "How do I add a new route to the external API?"

        Informational log output (which can be silenced with --quiet or by
        controlling the LOGGER_LEVEL) is emitted to STDERR. The AI's final
        response is printed to STDOUT, allowing you to pipe the output to other
        tools while still observing the research process.

          $ fnord ask my_project "How do I add a new route to the external API?" | glow -w140

        | FILE SUMMARIES

        When indexing the project, fnord generates a summary of each file to
        supplement semantic search and preempt some proportion of requests that
        the AI must make when answering question. The summary is typically a
        behavioral description of the file. To view the summary generated
        during the last index:

          $ fnord summary --project my_project --file /path/to/my_project/lib/my_module.ex

        | CONTROL THE LOG LEVEL

        fnord uses the erlang logger to emit informational messages to STDERR.
        You can control the log level if desired with the LOGGER_LEVEL
        environment variable.

          $ LOGGER_LEVEL=error fnord index --project my_project --dir /path/to/my_project
        """,
        allow_unknown_args: false,
        version: get_version(),
        subcommands: [
          index: [
            name: "index",
            about: "Index a project",
            options: [
              directory: directory,
              project: project,
              concurrency: concurrency,
              exclude: exclude
            ],
            flags: [reindex: reindex, quiet: quiet]
          ],
          ask: [
            name: "ask",
            about: "Ask the AI a question about the project",
            options: [concurrency: concurrency, include: include],
            args: [project: project, question: question],
            flags: [quiet: quiet]
          ],
          search: [
            name: "search",
            about: "Perform a semantic search within a project",
            options: [project: project, query: query, limit: limit, concurrency: concurrency],
            flags: [detail: detail]
          ],
          summary: [
            name: "summary",
            about: "Retrieve the AI-generated file summary used when indexing the file",
            options: [project: project, file: file]
          ],
          projects: [
            name: "projects",
            about: "Lists all projects",
            options: []
          ],
          files: [
            name: "files",
            about: "Lists all indexed files in a project",
            options: [project: project],
            flags: [relpath: relpath]
          ],
          torch: [
            name: "torch",
            about: "Deletes a previously indexed project from the database",
            options: [project: project]
          ],
          upgrade: [
            name: "upgrade",
            about: "Upgrade fnord to the latest version",
            flags: [yes: yes]
          ],
          test: [
            name: "test",
            about: "Test the tokenizer",
            options: []
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

    logger_level =
      System.get_env("LOGGER_LEVEL", "info")
      |> String.to_existing_atom()

    :ok = :logger.set_primary_config(:level, logger_level)
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
