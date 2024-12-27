defmodule Store.Prompt do
  @moduledoc """
  The `ask` subcommand saves useful prompts to the store. Saved prompts are
  accompanied by a title and a list of example questions for which the prompt
  is appropriate.

  When a prompt is saved, an embedding is generated from it to make the prompt
  (and the questions to which it applies) searchable.

  Whenever a prompt is modified or refined, the previous version is archived
  to the prompt's store dir with a version number:

    `<$STORE>/prompts/<$PROMPT_ID>./v<$VERSION>/`

  File structure:

  ```
  $HOME/
    -> .fnord/
      -> prompts/
        -> <$PROMPT_ID>/
          -> v1
            -> prompt.md
            -> questions.md
            -> embeddings.json
          -> v2
            -> prompt.md
            -> questions.md
            -> embeddings.json
  ```
  """

  defstruct [
    :store_path
  ]

  @store_dir "prompts"

  # -----------------------------------------------------------------------------
  # Instance functions
  # -----------------------------------------------------------------------------
  def new(), do: new(UUID.uuid4())

  def new(id) do
    %__MODULE__{
      store_path: build_store_dir(id)
    }
  end

  def exists?(prompt) do
    File.exists?(prompt.store_path)
  end

  def write(prompt, prompt_text, title, questions) do
    # --------------------------------------------------------------------------
    # Determine the versioned path for the new prompt.
    # --------------------------------------------------------------------------
    prompt_path = get_next_version_path(prompt)

    # --------------------------------------------------------------------------
    # Create the prompt's store path if it does not yet exist.
    # --------------------------------------------------------------------------
    File.mkdir_p!(prompt_path)

    # --------------------------------------------------------------------------
    # Write the prompt's text to the prompt's store path.
    # --------------------------------------------------------------------------
    prompt_path
    |> Path.join("prompt.md")
    |> File.write!(prompt_text)

    # --------------------------------------------------------------------------
    # Write the prompt's questions to the prompt's store path.
    # --------------------------------------------------------------------------
    search_text = """
    # #{title}
    #{questions}
    """

    prompt_path
    |> Path.join("questions.md")
    |> File.write!(search_text)

    # --------------------------------------------------------------------------
    # Generate and save embeddings for the prompt.
    # --------------------------------------------------------------------------
    embeddings_json =
      search_text
      |> generate_embeddings!()
      |> Jason.encode!()

    prompt_path
    |> Path.join("embeddings.json")
    |> File.write!(embeddings_json)

    {:ok, prompt}
  end

  def read(prompt) do
    with {:ok, version} <- get_current_version_number(prompt),
         {:ok, prompt_text} <- read_prompt(prompt, version),
         {:ok, questions} <- read_questions(prompt, version),
         {:ok, embeddings} <- read_embeddings(prompt, version) do
      {:ok,
       %{
         prompt: prompt_text,
         questions: questions,
         embeddings: embeddings,
         version: version
       }}
    end
  end

  def list_versions(prompt) do
    prompt.store_path
    |> File.ls()
    |> case do
      {:ok, dirs} -> Enum.sort(dirs)
      _ -> []
    end
  end

  # -----------------------------------------------------------------------------
  # Non-instnace functions
  # -----------------------------------------------------------------------------
  def list_prompts() do
    Store.store_home()
    |> Path.join(@store_dir)
    |> File.ls()
    |> case do
      {:ok, dirs} ->
        dirs
        |> Enum.sort()
        |> Enum.map(&new(&1))

      _ ->
        []
    end
  end

  def search(query) do
    needle = generate_embeddings!(query)

    list_prompts()
    |> Enum.reduce([], fn prompt, acc ->
      with {:ok, version} = get_current_version_number(prompt),
           {:ok, embeddings} <- read_embeddings(prompt, version) do
        score = AI.Util.cosine_similarity(needle, embeddings)
        [{score, prompt} | acc]
      else
        _ -> acc
      end
    end)
    |> Enum.sort(fn {a, _}, {b, _} -> a >= b end)
  end

  # ----------------------------------------------------------------------------
  # Private functions
  # ----------------------------------------------------------------------------
  defp read_prompt(prompt, version) do
    prompt.store_path
    |> Path.join("v#{version}")
    |> Path.join("prompt.md")
    |> File.read()
  end

  defp read_questions(prompt, version) do
    prompt.store_path
    |> Path.join("v#{version}")
    |> Path.join("questions.md")
    |> File.read()
  end

  defp read_embeddings(prompt, version) do
    prompt.store_path
    |> Path.join("v#{version}")
    |> Path.join("embeddings.json")
    |> File.read()
    |> case do
      {:ok, json} -> Jason.decode(json)
      error -> error
    end
  end

  defp generate_embeddings!(text) do
    AI.new()
    |> AI.get_embeddings(text)
    |> case do
      {:ok, embeddings} -> Enum.zip_with(embeddings, &Enum.max/1)
      {:error, reason} -> raise "Failed to generate embeddings: #{inspect(reason)}"
    end
  end

  defp get_current_version_path(prompt) do
    prompt
    |> list_versions()
    |> List.last()
    |> case do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp get_current_version_number(prompt) do
    prompt
    |> get_current_version_path()
    |> case do
      {:ok, path} ->
        path
        |> Path.basename()
        |> String.replace("v", "")
        |> String.to_integer()
        |> then(&{:ok, &1})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp get_next_version_number(prompt) do
    prompt
    |> get_current_version_number()
    |> case do
      {:ok, version} -> version + 1
      {:error, :not_found} -> 0
    end
  end

  defp get_next_version_path(prompt) do
    version = get_next_version_number(prompt)
    Path.join(prompt.store_path, "v#{version}")
  end

  defp build_store_dir(id) do
    Store.store_home()
    |> Path.join(@store_dir)
    |> Path.join(id)
  end
end