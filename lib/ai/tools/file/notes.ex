defmodule AI.Tools.File.Notes do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: Store.get_project() != {:error, :project_not_set}

  @impl AI.Tools
  def ui_note_on_request(_args), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def read_args(%{"file" => file}), do: {:ok, %{"file" => file}}
  def read_args(%{"file_path" => file}), do: {:ok, %{"file" => file}}
  def read_args(_args), do: AI.Tools.required_arg_error("file")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_notes_tool",
        description: """
        Returns the indexed summary of the specified file, or indicates that
        the file exists but has not been indexed yet. This is often MUCH more
        useful than the raw file contents, especially if the file may be large
        and you need only a high-level understanding of the file's purpose,
        behaviour, and linkage to other files.

        Use this before using the file_contents_tool to avoid pulling in
        unnecessary content into your context window.

        Scope: this tool only works on *indexed* source files. Gitignored
        paths (e.g. `scratch/` notes) are not indexed, but the tool will still
        confirm that such a file exists in the source repo if you're in a
        worktree session, and it will point you at file_contents_tool for
        actually reading the contents.
        """,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["file"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The absolute file path to the code file in the project.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, file} <- Map.fetch(args, "file"),
         {:ok, project} <- Store.get_project(),
         {:ok, resolved} <- Util.find_file_within_root(file, project.source_root) do
      # Build an entry key for this file path. The entry may or may not have
      # indexed data on disk - we return what we have either way.
      entry = Store.Project.Entry.new_from_file_path(project, resolved)
      summary = read_or_shim(fn -> Store.Project.Entry.read_summary(entry) end)

      {:ok, format_notes(resolved, summary)}
    else
      {:error, :project_not_set} ->
        {:error, "This project has not yet been indexed by the user."}

      {:error, :enoent} ->
        handle_enoent(args)

      :error ->
        {:error, "Missing required parameter: file."}
    end
  end

  # When the file isn't under the current project root, try the source-fallback
  # path. If it resolves (gitignored file present in the original source repo
  # but not in the worktree), return a stub notes response that acknowledges
  # existence and points the LLM at file_contents_tool for content. Otherwise
  # fall back to a friendlier error that mentions file_contents_tool as the
  # canonical way to read unindexed paths.
  defp handle_enoent(args) do
    file = Map.get(args, "file", "")

    case AI.Tools.resolve_source_fallback_path(file) do
      {:ok, source_path} ->
        {:ok, format_gitignored_notes(source_path)}

      _ ->
        {:error,
         """
         File path not found in the current project root: #{file}

         If this is a path you know exists but is not indexed (e.g. a
         gitignored file under `scratch/` or similar), use file_contents_tool
         instead - it reads files by path regardless of index status, and in
         a worktree session it will fall back to the original source repo
         for gitignored files.
         """}
    end
  end

  defp format_gitignored_notes(source_path) do
    """
    # File
    `#{source_path}`

    # Summary
    (not indexed - this file is gitignored and lives in the source repo,
    not the current worktree)

    # Reading the contents
    Use `file_contents_tool` with the same path you used here. In a worktree
    session it will automatically read this gitignored file from the source
    repo via source-fallback.
    """
  end

  # Returns indexed data if available, otherwise a placeholder indicating the
  # file hasn't been indexed yet.
  defp read_or_shim(reader) do
    case reader.() do
      {:ok, content} -> content
      {:error, _} -> "(not indexed)"
    end
  end

  defp format_notes(file, summary) do
    """
    # File
    `#{file}`

    # Summary
    #{summary}
    """
  end
end
