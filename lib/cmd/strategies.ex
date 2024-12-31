defmodule Cmd.Strategies do
  @behaviour Cmd

  @impl Cmd
  def spec() do
    [
      strategies: [
        name: "strategies",
        about: "List all saved research strategies"
      ]
    ]
  end

  @impl Cmd
  def run(_opts) do
    Store.Prompt.install_initial_strategies()

    Store.list_prompts()
    |> Enum.map(fn prompt ->
      with {:ok, title} <- Store.Prompt.read_title(prompt),
           {:ok, prompt_text} <- Store.Prompt.read_prompt(prompt),
           {:ok, questions} <- Store.Prompt.read_questions(prompt) do
        """
        # #{title}
        **ID:** #{prompt.id}

        **Questions:**
        #{questions}

        **Prompt:**
        #{prompt_text}
        """
      end
    end)
    |> Enum.join("\n\n-----\n\n")
    |> IO.puts()
  end
end
