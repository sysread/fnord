defmodule Outputs do
  @moduledoc """
  Helpers for persisting raw assistant outputs for a project.

  Outputs are written under:

      ~/fnord/outputs/projects/<project_id>/outputs/<slug>.md

  The content saved is the *raw* assistant response.
  """

  @typedoc """
  Represents a project identifier.
  """
  @type project_id :: String.t()

  @typedoc """
  The raw response text from the assistant.
  """
  @type raw_response :: String.t()

  @typedoc """
  A conversation identifier used for default slug generation.
  """
  @type conversation_id :: String.t()

  @typedoc """
  A slug generated for output filenames.
  """
  @type slug :: String.t()

  @typedoc """
  The path to an output file.
  """
  @type output_path :: String.t()

  @typedoc """
  Options for the save function, currently supported keys:
  - :conversation_id - a conversation_id
  """
  @type save_opts :: [conversation_id: conversation_id]

  @typedoc """
  Result of a save operation.
  On success returns {:ok, output_path}, on failure {:error, reason}.
  """
  @type save_result :: {:ok, output_path} | {:error, term()}

  @doc """
  Returns the directory path for outputs for a given project.
  Uses Settings.get_user_home() and returns ~/fnord/outputs/projects/<project_id>/outputs.
  """
  @spec outputs_dir(project_id()) :: String.t()
  def outputs_dir(project_id) when is_binary(project_id) do
    Path.join([
      Settings.get_user_home(),
      "fnord",
      "outputs",
      "projects",
      project_id,
      "outputs"
    ])
  end

  @doc """
  Saves the raw assistant markdown response for a project.
  Derives the filename slug from the first line "# Title: ..." if present, falls back to "conversation-<conversation_id>" or "untitled".
  Resolves filename collisions by appending "-N".
  Uses FileLock.with_lock and Settings.write_atomic! for atomic writes.
  Returns {:ok, output_path} on success or {:error, reason} on failure.
  """
  @spec save(project_id(), raw_response(), save_opts()) :: save_result()
  def save(project_id, raw_response, opts \\ [])
      when is_binary(project_id) and
             is_binary(raw_response) and
             is_list(opts) do
    dir = outputs_dir(project_id)
    File.mkdir_p!(dir)

    slug =
      case extract_title(raw_response) do
        title when is_binary(title) and title != "" ->
          slugified = slugify(title)
          if slugified != "", do: slugified, else: default_slug(opts)

        _ ->
          default_slug(opts)
      end

    path = unique_path(dir, slug)
    lock_path = path <> ".lock"

    case FileLock.with_lock(lock_path, fn ->
           Settings.write_atomic!(path, raw_response)
           path
         end) do
      {:ok, result} when is_binary(result) ->
        {:ok, result}

      {:ok, other} ->
        {:error, other}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Extracts the title from the raw response.
  Expects the first line in the format "# Title: <title>" (case-insensitive).
  Returns the trimmed title or nil if missing or blank.
  """
  @spec extract_title(raw_response()) :: String.t() | nil
  def extract_title(raw_response) when is_binary(raw_response) do
    raw_response
    |> String.split("\n", parts: 2)
    |> List.first()
    |> case do
      nil ->
        nil

      first_line ->
        case Regex.run(~r/^# Title:\s*(.+)$/i, first_line) do
          [_, title] ->
            trimmed = String.trim(title)
            if trimmed == "", do: nil, else: trimmed

          _ ->
            nil
        end
    end
  end

  @doc """
  Converts a text string into a URL-friendly slug.
  Lowercases, trims whitespace, replaces non-alphanumeric characters with hyphens, and trims leading/trailing hyphens.
  """
  @spec slugify(String.t()) :: slug()
  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.trim()
    |> then(&Regex.replace(~r/[^a-z0-9]+/, &1, "-"))
    |> String.trim("-")
  end

  @spec default_slug(Keyword.t()) :: String.t()
  defp default_slug(opts) when is_list(opts) do
    case Keyword.get(opts, :conversation_id) do
      id when is_binary(id) and id != "" ->
        "conversation-#{id}"

      _ ->
        "untitled"
    end
  end

  @spec unique_path(String.t(), String.t(), non_neg_integer()) :: String.t()
  defp unique_path(dir, slug, counter \\ 0)
       when is_binary(dir) and is_binary(slug) and is_integer(counter) and counter >= 0 do
    filename =
      if counter == 0 do
        "#{slug}.md"
      else
        "#{slug}-#{counter}.md"
      end

    path = Path.join(dir, filename)

    if File.exists?(path) do
      unique_path(dir, slug, counter + 1)
    else
      path
    end
  end
end
