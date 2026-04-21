defmodule Store.Project.CommitDocument do
  @moduledoc """
  Builds the bounded canonical text used to embed git commits for a project.

  The document keeps commit semantics isolated from file and conversation
  indexing while still producing a stable text form that can be hashed for
  stale detection when the document format or embedding model changes.
  """

  @type commit :: %{
          sha: String.t(),
          parent_shas: [String.t()],
          subject: String.t(),
          body: String.t(),
          author: String.t(),
          committed_at: String.t() | DateTime.t() | non_neg_integer(),
          changed_files: [String.t()],
          diffstat: String.t() | [map()]
        }

  @document_version 1

  @spec version() :: non_neg_integer()
  def version do
    @document_version
  end

  @doc """
  Builds the bounded canonical commit document used for embeddings.

  The shape stays deliberately small so commit histories can be hashed and
  reindexed deterministically without embedding unbounded patch text.
  """
  @spec build(%{
          sha: binary(),
          parent_shas: [binary()],
          subject: binary(),
          body: binary(),
          author: binary(),
          committed_at: binary() | non_neg_integer() | DateTime.t(),
          changed_files: [binary()],
          diffstat: binary() | [map()]
        }) :: {binary(), binary()}
  def build(commit) do
    document =
      [
        "commit: #{commit.sha}",
        "parents: #{Enum.join(commit.parent_shas, ", ")}",
        "author: #{commit.author}",
        "committed_at: #{format_committed_at(commit.committed_at)}",
        "subject: #{normalize_line(commit.subject)}",
        "body:",
        bounded_body(commit.body),
        "changed_files:",
        Enum.map_join(commit.changed_files, "\n", &format_changed_file/1),
        "diffstat:",
        format_diffstat(commit.diffstat),
        "document_version: #{@document_version}"
      ]
      |> Enum.join("\n")

    {document, doc_hash(document)}
  end

  @doc """
  Hashes the canonical commit document so callers can compare stable semantic
  content rather than raw commit metadata.
  """
  @spec doc_hash(binary()) :: binary()
  def doc_hash(document) when is_binary(document) do
    :crypto.hash(:sha256, document)
    |> Base.encode16(case: :lower)
  end

  defp bounded_body(body) when is_binary(body) do
    body
    |> String.trim()
    |> String.split("\n")
    |> Enum.take(60)
    |> Enum.join("\n")
  end

  defp bounded_body(_), do: ""

  defp format_changed_file(path) when is_binary(path), do: "- #{path}"
  defp format_changed_file(path), do: "- #{inspect(path)}"

  defp format_diffstat(diffstat) when is_binary(diffstat), do: diffstat

  defp format_diffstat(diffstat) when is_list(diffstat) do
    Enum.map_join(diffstat, "\n", fn stat ->
      file = Map.get(stat, :file) || Map.get(stat, "file") || ""
      additions = Map.get(stat, :additions) || Map.get(stat, "additions") || 0
      deletions = Map.get(stat, :deletions) || Map.get(stat, "deletions") || 0
      "#{file} | +#{additions} -#{deletions}"
    end)
  end

  defp format_diffstat(_), do: ""

  defp format_committed_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_committed_at(int) when is_integer(int), do: Integer.to_string(int)
  defp format_committed_at(value) when is_binary(value), do: value
  defp format_committed_at(_), do: ""

  defp normalize_line(value) when is_binary(value), do: String.replace(value, "\n", " ")
  defp normalize_line(value), do: inspect(value)
end
