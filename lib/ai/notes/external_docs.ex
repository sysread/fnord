defmodule AI.Notes.ExternalDocs do
  @moduledoc """
  Discover and read external documentation files (CLAUDE.md and AGENTS.md).

  This module searches for these files in the project root, current
  working directory, and standard user directories, returning a list of
  `{type, path, contents}` tuples.
  """

  @type doc_type :: :claude | :agents
  @type path :: String.t()
  @type display_path :: String.t()
  @type contents :: String.t()
  @type doc_result :: {doc_type, path, display_path, contents}

  @max_file_size 1_000_000

  @spec get_docs() :: [doc_result]
  def get_docs do
    project_root = Path.expand("../../../", __DIR__)
    cwd = Path.expand(File.cwd!())
    user_home = System.get_env("HOME") || System.user_home!()

    # Define sources in order of specificity: home files, project files, cwd files
    sources = [
      # Home directory files (most general)
      {:claude, Path.join(user_home, ".claude/CLAUDE.md"), "~/.claude/CLAUDE.md"},
      {:claude, Path.join(user_home, ".config/claude/CLAUDE.md"), "~/.config/claude/CLAUDE.md"},
      {:agents, Path.join(user_home, ".agents/AGENTS.md"), "~/.agents/AGENTS.md"},
      {:agents, Path.join(user_home, ".config/agents/AGENTS.md"), "~/.config/agents/AGENTS.md"},
      
      # Project root files (more specific)
      {:claude, Path.join(project_root, "CLAUDE.md"), get_relative_path(Path.join(project_root, "CLAUDE.md"), cwd)},
      {:agents, Path.join(project_root, "AGENTS.md"), get_relative_path(Path.join(project_root, "AGENTS.md"), cwd)},
      
      # Current working directory files (most specific)
      {:claude, Path.join(cwd, "CLAUDE.md"), "./CLAUDE.md"},
      {:agents, Path.join(cwd, "AGENTS.md"), "./AGENTS.md"}
    ]

    for {type, path, display_path} <- sources,
        result = read_doc(type, path, display_path),
        result != nil,
        do: result
  end

  defp read_doc(type, path, display_path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @max_file_size ->
        UI.warn("Skipping large file", path)
        nil

      {:ok, _stat} ->
        case File.read(path) do
          {:ok, contents} ->
            {type, path, display_path, contents}

          {:error, reason} ->
            UI.warn("Unable to read file", "#{path}: #{inspect(reason)}")
            nil
        end

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        UI.warn("Unable to access file", "#{path}: #{inspect(reason)}")
        nil
    end
  end

  defp get_relative_path(target_path, from_path) do
    Path.relative_to(target_path, from_path)
  end
end
