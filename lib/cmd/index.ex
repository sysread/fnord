defmodule Cmd.Index do
  @behaviour Cmd

  defstruct [
    :opts,
    :indexer_module,
    :indexer,
    :project
  ]

  @impl Cmd
  def spec do
    [
      index: [
        name: "index",
        about: "Index a project",
        options: [
          directory: [
            value_name: "DIR",
            long: "--dir",
            short: "-d",
            help:
              "Directory to index (required for first index or reindex after moving the project)",
            required: false
          ],
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ],
          workers: [
            value_name: "WORKERS",
            long: "--workers",
            short: "-w",
            help: "Number of concurrent workers to use",
            parser: :integer,
            default: Cmd.default_workers()
          ],
          exclude: [
            value_name: "FILE",
            long: "--exclude",
            short: "-x",
            help:
              "Exclude a file, directory, or glob from being indexed; this is stored in the project's configuration and used on subsequent indexes",
            multiple: true
          ]
        ],
        flags: [
          defrag_notes: [
            long: "--defrag-notes",
            short: "-D",
            help: "Consolidate saved notes",
            default: false
          ],
          reindex: [
            long: "--reindex",
            short: "-r",
            help: "Reindex the project",
            default: false
          ],
          quiet: [
            long: "--quiet",
            short: "-Q",
            help: "Suppress interactive output; automatically enabled when executed in a pipe",
            required: false,
            default: false
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts) do
    opts
    |> new()
    |> perform_task()
  end

  def perform_task(idx) do
    UI.info("Project", idx.project.name)
    UI.info("   Root", idx.project.source_root)
    UI.info("Exclude", Enum.join(idx.project.exclude, " | ") || "None")

    Cmd.Index.Embeddings.index_project(idx)
    Cmd.Index.Notes.defrag(idx)
  end

  def new(opts, indexer \\ Indexer) do
    with {:ok, project_name} <- Map.fetch(opts, :project) do
      Application.put_env(:fnord, :project, project_name)
    end

    project =
      Store.get_project()
      |> Store.Project.save_settings(
        Map.get(opts, :directory),
        Map.get(opts, :exclude)
      )

    if is_nil(project.source_root) do
      raise """
      Error: the project root was not found in the settings file.

      This can happen under the following circumstances:
        - the first index of a project
        - the first index reindexing after moving the project directory
        - the first index after the upgrade that made --dir optional
      """
    end

    %__MODULE__{
      opts: opts,
      indexer_module: indexer,
      indexer: indexer.new(),
      project: project
    }
  end
end
