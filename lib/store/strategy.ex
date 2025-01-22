defmodule Store.Strategy do
  @moduledoc """
  The `ask` subcommand saves useful prompts to the store. Saved prompts are
  accompanied by a title and a list of example questions for which the prompt
  is appropriate.

  When a research strategy prompt is saved, an embedding is generated from it
  to make the prompt (and the questions to which it applies) searchable.

  `<$STORE>/prompts/<$PROMPT_ID>./`

  File structure:

  ```
  $HOME/
    -> .fnord/
      -> prompts/
        -> <$PROMPT_ID>/
          -> title.md
          -> prompt.md
          -> questions.md
          -> embeddings.json
  ```

  There are a number of initial prompts that are installed the first time the
  prompt store is searched. These prompts are defined in
  `data/strategies.yaml`. When a new version of fnord is installed, the next
  time the prompt store is searched, the prompts will be updated to the latest
  versions. 

  Note that `data/strategies.yaml` is read at *compile time* and is not itself
  a part of the release binary.
  """

  defstruct [
    :id,
    :store_path
  ]

  @store_dir "strategies"

  # ----------------------------------------------------------------------------
  # These are installed the first time the prompt store is searched.
  # ----------------------------------------------------------------------------
  @strategies_file "data/strategies.yaml"
  @external_resource @strategies_file
  @initial_strategies YamlElixir.read_from_file!(@strategies_file)

  @doc """
  Create a new prompt with a random UUID.
  """
  def new(), do: new(UUID.uuid4())

  @doc """
  Create a new prompt with the given ID. This is used to access an existing
  prompt. If `id` is `nil`, acts as an alias for `new/0`.
  """
  def new(nil), do: new(UUID.uuid4())
  def new(id), do: %__MODULE__{id: id, store_path: build_store_dir(id)}

  @doc """
  Returns true if the prompt has been written to the store.
  """
  def exists?(prompt) do
    File.exists?(prompt.store_path)
  end

  @doc """
  Saves the prompt to the store. If the prompt already exists but thew `title`,
  `prompt_text`, or `questions` have changed, it will be replaced by the new
  version. If they have not changed, an error will be returned:
    `{:error, {:strategy_exists, id}}`
  """
  def write(prompt, title, prompt_text, questions) do
    qstr = format_questions(questions)

    Store.list_strategies()
    |> Enum.find(fn p ->
      with {:ok, old_title} when old_title == title <- read_title(p),
           {:ok, old_prompt} when old_prompt == prompt_text <- read_prompt(p),
           {:ok, old_questions} when old_questions == qstr <- read_questions(p) do
        true
      else
        _ -> false
      end
    end)
    |> case do
      nil -> do_write(prompt, title, prompt_text, questions)
      p -> {:error, {:strategy_exists, p.id}}
    end
  end

  defp do_write(prompt, title, prompt_text, questions) do
    # --------------------------------------------------------------------------
    # We only reach this point if we want to *overwrite* the prompt, so we
    # remove the existing prompt files.
    # --------------------------------------------------------------------------
    File.rm_rf!(prompt.store_path)

    # --------------------------------------------------------------------------
    # Create the prompt's store path if it does not yet exist.
    # --------------------------------------------------------------------------
    File.mkdir_p!(prompt.store_path)

    # --------------------------------------------------------------------------
    # Write the title to the prompt's store path.
    # --------------------------------------------------------------------------
    prompt.store_path
    |> Path.join("title.md")
    |> File.write!(title)

    # --------------------------------------------------------------------------
    # Write the prompt's text to the prompt's store path.
    # --------------------------------------------------------------------------
    prompt.store_path
    |> Path.join("prompt.md")
    |> File.write!(prompt_text)

    # --------------------------------------------------------------------------
    # Write the prompt's questions to the prompt's store path.
    # --------------------------------------------------------------------------
    questions = format_questions(questions)

    prompt.store_path
    |> Path.join("questions.md")
    |> File.write!(questions)

    # --------------------------------------------------------------------------
    # Generate and save embeddings for the prompt.
    # --------------------------------------------------------------------------
    embeddings_text = [title, prompt_text, questions] |> Enum.join("\n")

    with {:ok, embeddings} <- get_embeddings(embeddings_text),
         {:ok, json} <- Jason.encode(embeddings),
         :ok <- prompt.store_path |> Path.join("embeddings.json") |> File.write(json) do
      {:ok, prompt}
    end
  end

  @doc """
  Reads the prompt from the store. If the prompt does not exist, an error will
  be returned (`{:error, :not_found}`). Returns an `:ok` tuple with the prompt's
  title, prompt text, questions, and embeddings:
  ```
  {:ok,
   %{
     title: title,
     prompt: prompt_text,
     questions: questions,
     embeddings: embeddings,
   }}
  ```
  """
  def read(prompt) do
    with {:ok, title} <- read_title(prompt),
         {:ok, prompt_text} <- read_prompt(prompt),
         {:ok, questions} <- read_questions(prompt),
         {:ok, embeddings} <- read_embeddings(prompt) do
      {:ok,
       %{
         title: title,
         prompt: prompt_text,
         questions: questions,
         embeddings: embeddings
       }}
    end
  end

  def read_title(prompt) do
    prompt.store_path
    |> Path.join("title.md")
    |> File.read()
  end

  def read_prompt(prompt) do
    prompt.store_path
    |> Path.join("prompt.md")
    |> File.read()
  end

  def read_questions(prompt) do
    prompt.store_path
    |> Path.join("questions.md")
    |> File.read()
  end

  def read_embeddings(prompt) do
    prompt.store_path
    |> Path.join("embeddings.json")
    |> File.read()
    |> case do
      {:ok, json} -> Jason.decode(json)
      error -> error
    end
  end

  # ----------------------------------------------------------------------------
  # Private functions
  # ----------------------------------------------------------------------------
  defp get_embeddings(input) do
    Indexer.impl().new()
    |> Indexer.impl().get_embeddings(input)
  end

  defp format_questions(questions) do
    questions
    |> Enum.map(&"- #{&1}")
    |> Enum.join("\n")
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
    delete_old_prompts_dir()

    @initial_strategies
    |> Enum.each(fn %{
                      "id" => id,
                      "title" => title,
                      "prompt" => prompt_str,
                      "questions" => questions
                    } ->
      prompt = new(id)

      if differs?(prompt, prompt_str, questions) do
        UI.info("Saving new or updated research prompt: #{title}")
        write(prompt, title, prompt_str, questions)
      end
    end)
  end

  defp differs?(prompt, prompt_str, questions) do
    if exists?(prompt) do
      with {:ok, old_questions} <- read_questions(prompt),
           {:ok, old_prompt} <- read_prompt(prompt) do
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

  # ----------------------------------------------------------------------------
  # We used to store versioned strategies that could be updated, but we no
  # longer do so because they were not very valuable. So we check for the
  # existence of the old style of directory and delete all of those versioned
  # entries. They can be identified because they had a different store dir
  # (prompts, rather than strategies).
  # ----------------------------------------------------------------------------
  defp delete_old_prompts_dir do
    old_prompts_dir =
      Store.store_home()
      |> Path.join("prompts")

    if File.exists?(old_prompts_dir) do
      File.rm_rf!(old_prompts_dir)
    end
  end
end
