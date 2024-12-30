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
            -> title.md
            -> prompt.md
            -> questions.md
            -> embeddings.json
          -> v2
            -> title.md
            -> prompt.md
            -> questions.md
            -> embeddings.json
  ```

  There are a number of initial prompts that are installed the first time the
  prompt store is searched. These prompts are defined in `data/prompts.yaml`.
  When a new version of fnord is installed, the next time the prompt store is
  searched, the prompts will be updated to the latest versions. "Default"
  prompts can be distinguished by using a title slug for its id, rather than a
  UUID.
  """

  defstruct [
    :id,
    :store_path
  ]

  @store_dir "prompts"

  # ----------------------------------------------------------------------------
  # These are installed the first time the prompt store is searched.
  # ----------------------------------------------------------------------------
  @initial_strategies YamlElixir.read_from_file!("data/prompts.yaml")

  # -----------------------------------------------------------------------------
  # Instance functions
  # -----------------------------------------------------------------------------
  def new(), do: new(UUID.uuid4())
  def new(nil), do: new(UUID.uuid4())

  def new(id) do
    %__MODULE__{id: id, store_path: build_store_dir(id)}
  end

  def exists?(prompt) do
    File.exists?(prompt.store_path)
  end

  def version(prompt) do
    get_current_version_number(prompt)
  end

  def write(prompt, title, prompt_text, questions) do
    qstr = format_questions(questions)

    list_prompts()
    |> Enum.find(fn p ->
      with {:ok, version} <- get_current_version_number(p),
           {:ok, old_title} when old_title == title <- read_title(p, version),
           {:ok, old_prompt} when old_prompt == prompt_text <- read_prompt(p, version),
           {:ok, old_questions} when old_questions == qstr <- read_questions(p, version) do
        true
      else
        _ -> false
      end
    end)
    |> case do
      nil -> do_write(prompt, title, prompt_text, questions)
      p -> {:error, {:prompt_exists, p.id}}
    end
  end

  defp do_write(prompt, title, prompt_text, questions) do
    # --------------------------------------------------------------------------
    # Determine the versioned path for the new prompt.
    # --------------------------------------------------------------------------
    prompt_path = get_next_version_path(prompt)

    # --------------------------------------------------------------------------
    # Create the prompt's store path if it does not yet exist.
    # --------------------------------------------------------------------------
    File.mkdir_p!(prompt_path)

    # --------------------------------------------------------------------------
    # Write the title to the prompt's store path.
    # --------------------------------------------------------------------------
    prompt_path
    |> Path.join("title.md")
    |> File.write!(title)

    # --------------------------------------------------------------------------
    # Write the prompt's text to the prompt's store path.
    # --------------------------------------------------------------------------
    prompt_path
    |> Path.join("prompt.md")
    |> File.write!(prompt_text)

    # --------------------------------------------------------------------------
    # Write the prompt's questions to the prompt's store path.
    # --------------------------------------------------------------------------
    questions = format_questions(questions)

    prompt_path
    |> Path.join("questions.md")
    |> File.write!(questions)

    # --------------------------------------------------------------------------
    # Generate and save embeddings for the prompt.
    # --------------------------------------------------------------------------
    embeddings_json =
      "# #{title}\n#{prompt_text}\n\n#{questions}"
      |> generate_embeddings!()
      |> Jason.encode!()

    prompt_path
    |> Path.join("embeddings.json")
    |> File.write!(embeddings_json)

    {:ok, prompt}
  end

  def read(prompt) do
    with {:ok, version} <- get_current_version_number(prompt) do
      read(prompt, version)
    end
  end

  def read(prompt, version) do
    with {:ok, title} <- read_title(prompt, version),
         {:ok, prompt_text} <- read_prompt(prompt, version),
         {:ok, questions} <- read_questions(prompt, version),
         {:ok, embeddings} <- read_embeddings(prompt, version) do
      {:ok,
       %{
         title: title,
         prompt: prompt_text,
         questions: questions,
         embeddings: embeddings,
         version: version
       }}
    end
  end

  def read_title(prompt) do
    with {:ok, version} <- get_current_version_number(prompt) do
      read_title(prompt, version)
    end
  end

  def read_title(prompt, version) do
    prompt.store_path
    |> Path.join("v#{version}")
    |> Path.join("title.md")
    |> File.read()
  end

  def read_prompt(prompt) do
    with {:ok, version} <- get_current_version_number(prompt) do
      read_prompt(prompt, version)
    end
  end

  def read_prompt(prompt, version) do
    prompt.store_path
    |> Path.join("v#{version}")
    |> Path.join("prompt.md")
    |> File.read()
  end

  def read_questions(prompt) do
    with {:ok, version} <- get_current_version_number(prompt) do
      read_questions(prompt, version)
    end
  end

  def read_questions(prompt, version) do
    prompt.store_path
    |> Path.join("v#{version}")
    |> Path.join("questions.md")
    |> File.read()
  end

  def read_embeddings(prompt) do
    with {:ok, version} <- get_current_version_number(prompt) do
      read_embeddings(prompt, version)
    end
  end

  def read_embeddings(prompt, version) do
    prompt.store_path
    |> Path.join("v#{version}")
    |> Path.join("embeddings.json")
    |> File.read()
    |> case do
      {:ok, json} -> Jason.decode(json)
      error -> error
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
  # Common functions
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

  def search(query, max_results \\ 10) do
    install_initial_strategies()

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
    |> Enum.take(max_results)
  end

  # ----------------------------------------------------------------------------
  # Private functions
  # ----------------------------------------------------------------------------
  defp generate_embeddings!(text) do
    AI.new()
    |> AI.get_embeddings(text)
    |> case do
      {:ok, embeddings} -> Enum.zip_with(embeddings, &Enum.max/1)
      {:error, reason} -> raise "Failed to generate embeddings: #{inspect(reason)}"
    end
  end

  defp format_questions(questions) do
    questions
    |> Enum.map(&"- #{&1}")
    |> Enum.join("\n")
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

  # ----------------------------------------------------------------------------
  # Initial strategies
  # ----------------------------------------------------------------------------
  def install_initial_strategies() do
    @initial_strategies
    |> Enum.each(fn %{
                      "id" => id,
                      "title" => title,
                      "prompt" => prompt_str,
                      "questions" => questions
                    } ->
      prompt = new(id)

      if differs?(prompt, prompt_str, questions) do
        UI.info("Saving research prompt: #{title}")
        write(prompt, title, prompt_str, questions)
      end
    end)
  end

  defp differs?(prompt, prompt_str, questions) do
    if exists?(prompt) do
      with {:ok, version} <- get_current_version_number(prompt),
           {:ok, old_questions} <- read_questions(prompt, version),
           {:ok, old_prompt} <- read_prompt(prompt, version) do
        cond do
          old_questions != format_questions(questions) -> true
          old_prompt != prompt_str -> true
          true -> false
        end
      else
        _ -> true
      end
    else
      true
    end
  end
end
