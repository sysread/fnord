defmodule Cmd.ShellCompletion do
  @behaviour Cmd
  @supported_shells ["bash", "zsh"]

  @impl true
  def spec do
    [
      shell_completion: [
        name: "shell-completion",
        about: "Generate shell completion scripts",
        description: """
        """,
        options: [
          shell: [
            short: "-s",
            long: "--shell",
            default: "bash",
            help: """
            Shell type (#{Enum.join(@supported_shells, "/")})

            Add to your shell config:
              eval "$(cmd shell-completion -s bash)"

            """
          ]
        ]
      ]
    ]
  end

  @impl true
  def run(args, _unknown) do
    with {:ok, shell} <- get_shell(args) do
      Fnord.spec()
      |> Shell.FromOptimus.convert()
      |> Shell.Completion.generate(shell: shell)
      |> IO.puts()
    else
      {:error, reason} -> IO.puts(:stderr, reason)
    end
  end

  defp get_shell(%{shell: "bash"}), do: {:ok, :bash}
  defp get_shell(%{shell: "zsh"}), do: {:ok, :zsh}
  defp get_shell(%{shell: other}), do: {:error, "Unsupported shell type: #{other}"}
end
