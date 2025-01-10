defmodule Store.PromptTest do
  use Fnord.TestCase

  alias Store.Prompt

  setup do: set_config(workers: 1, quiet: true)
  setup do: {:ok, project: mock_project("blarg")}

  test "new/0" do
    prompt = Prompt.new()
    assert prompt.store_path == Path.join(Store.store_home(), "prompts/#{prompt.id}")
    refute is_nil(prompt.id)
    refute Prompt.exists?(prompt)
    assert [] = Prompt.list_versions(prompt)
  end

  test "new/1: w/ nil id" do
    prompt = Prompt.new(nil)
    assert prompt.store_path == Path.join(Store.store_home(), "prompts/#{prompt.id}")
    refute is_nil(prompt.id)
    refute Prompt.exists?(prompt)
    assert [] = Prompt.list_versions(prompt)
  end

  test "new/1: w/ id" do
    prompt = Prompt.new("DEADBEEF")
    assert prompt.store_path == Path.join(Store.store_home(), "prompts/#{prompt.id}")
    assert prompt.id == "DEADBEEF"
    refute Prompt.exists?(prompt)
    assert [] = Prompt.list_versions(prompt)
  end

  test "write <=> read" do
    title = "Doing the thing"
    prompt_str = "Do the thing; verify if thing is done; report doneness of thing"
    questions = ["What is the thing?", "How do you do the thing?"]
    questions_str = questions |> Enum.map(&"- #{&1}") |> Enum.join("\n")

    # ---------------------------------------------------------------------------
    # Create a new prompt that has not yet been saved
    # ---------------------------------------------------------------------------
    prompt = Prompt.new()
    refute Prompt.exists?(prompt)
    assert [] = Prompt.list_versions(prompt)

    # --------------------------------------------------------------------------
    # Save the prompt
    # --------------------------------------------------------------------------
    assert {:ok, ^prompt} = Prompt.write(prompt, title, prompt_str, questions)

    assert Prompt.exists?(prompt)
    assert {:ok, version} = Prompt.version(prompt)
    assert ["v0"] = Prompt.list_versions(prompt)

    version_dir = prompt.store_path |> Path.join("v#{version}")
    assert File.exists?(version_dir |> Path.join("title.md"))
    assert File.exists?(version_dir |> Path.join("prompt.md"))
    assert File.exists?(version_dir |> Path.join("questions.md"))
    assert File.exists?(version_dir |> Path.join("embeddings.json"))

    assert {:ok, ^title} = Prompt.read_title(prompt)
    assert {:ok, ^prompt_str} = Prompt.read_prompt(prompt)
    assert {:ok, ^questions_str} = Prompt.read_questions(prompt)
    assert {:ok, [1, 2, 3]} = Prompt.read_embeddings(prompt)

    assert {:ok,
            %{
              title: ^title,
              prompt: ^prompt_str,
              questions: ^questions_str,
              embeddings: [1, 2, 3],
              version: ^version
            }} = Prompt.read(prompt)

    # --------------------------------------------------------------------------
    # Try to save it again with the same parameters, which should fail.
    # --------------------------------------------------------------------------
    id = prompt.id

    assert {:error, {:prompt_exists, ^id}} = Prompt.write(prompt, title, prompt_str, questions)

    # --------------------------------------------------------------------------
    # Try to save it again with different parameters, which should succeed.
    # --------------------------------------------------------------------------
    v2_title = "Doing the thing - but slightly different this time"

    assert {:ok, ^prompt} = Prompt.write(prompt, v2_title, prompt_str, questions)

    assert ["v0", "v1"] = Prompt.list_versions(prompt)

    # --------------------------------------------------------------------------
    # Test whether versioned reads behave correctly
    # --------------------------------------------------------------------------
    assert {:ok,
            %{
              title: ^title,
              prompt: ^prompt_str,
              questions: ^questions_str,
              embeddings: [1, 2, 3],
              version: 0
            }} = Prompt.read(prompt, 0)

    assert {:ok,
            %{
              title: ^v2_title,
              prompt: ^prompt_str,
              questions: ^questions_str,
              embeddings: [1, 2, 3],
              version: 1
            }} = Prompt.read(prompt, 1)
  end
end
