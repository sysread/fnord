defmodule Cmd.Strategies do
  def run(_opts) do
    Store.Prompt.install_initial_strategies()

    Store.Prompt.list_prompts()
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
