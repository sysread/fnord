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
        Returns a summary and outline of the specified file if it has been
        indexed, or indicates that the file exists but has not been indexed
        yet. This is often MUCH more useful than the raw file contents,
        especially if the file may be large and you need only a high-level
        understanding of the file's purpose, behaviour, and linkage to
        other files.

        Use this before using the file_contents_tool to avoid pulling in
        unnecessary content into your context window.
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
      outline = read_or_shim(fn -> Store.Project.Entry.read_outline(entry) end)

      {:ok, format_notes(resolved, summary, outline)}
    else
      {:error, :project_not_set} ->
        {:error, "This project has not yet been indexed by the user."}

      {:error, :enoent} ->
        {:error, "File path not found. Please verify the correct path."}

      :error ->
        {:error, "Missing required parameter: file."}
    end
  end

  # Returns indexed data if available, otherwise a placeholder indicating the
  # file hasn't been indexed yet.
  defp read_or_shim(reader) do
    case reader.() do
      {:ok, content} -> content
      {:error, _} -> "(not indexed)"
    end
  end

  defp format_notes(file, summary, outline) do
    """
    # File
    `#{file}`

    # Summary
    #{summary}

    # Outline
    #{outline}
    """
  end
end
