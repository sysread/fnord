defmodule LayoutMigrationHelpers do
  @moduledoc """
  Test helpers for simulating legacy entry directories and asserting migration to the files/ layout.
  """
  import ExUnit.Assertions

  @doc """
  Creates a legacy entry directory at the project root with a metadata.json pointing to a corresponding source file.

  Returns a tuple {basename, rel_file}, where basename is the directory name and rel_file is the relative source filename.
  """
  @spec create_legacy_entry(Store.Project.t(), String.t() | nil) :: {String.t(), String.t()}
  def create_legacy_entry(project, basename \\ nil) do
    basename = basename || "entry_#{:erlang.unique_integer([:positive])}"
    rel_file = "#{basename}.txt"
    # Create legacy directory under the project store path
    legacy_dir = Path.join(project.store_path, basename)
    File.mkdir_p!(legacy_dir)
    # Write metadata.json referencing the relative file path
    metadata = %{"file" => rel_file}
    File.write!(Path.join(legacy_dir, "metadata.json"), Jason.encode!(metadata))
    # Ensure project source root and create the source file
    File.mkdir_p!(project.source_root)
    File.write!(Path.join(project.source_root, rel_file), "")
    {basename, rel_file}
  end

  @doc """
  Asserts that the legacy entry directory has been moved into the project's files_root directory and that metadata.json's "file" field matches rel_file.
  """
  @spec assert_migrated(Store.Project.t(), String.t(), String.t()) :: :ok
  def assert_migrated(project, basename, rel_file) do
    # Legacy root dir should not exist
    legacy_dir = Path.join(project.store_path, basename)
    refute File.dir?(legacy_dir)
    # New directory under files_root should exist
    files_root = Store.Project.files_root(project)
    new_dir = Path.join(files_root, basename)
    assert File.dir?(new_dir)
    # metadata.json should reference the correct file
    content = File.read!(Path.join(new_dir, "metadata.json"))

    case Jason.decode(content) do
      {:ok, %{"file" => ^rel_file}} ->
        :ok

      {:ok, data} ->
        flunk("Expected metadata 'file' to be #{inspect(rel_file)}, got #{inspect(data)}")

      {:error, reason} ->
        flunk("Failed to decode metadata.json: #{inspect(reason)}")
    end
  end
end
