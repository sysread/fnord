defmodule Cmd.ShellCompletion do
  @behaviour Cmd
  @supported_shells ["bash", "zsh"]

  @impl true
  def spec do
    [
      shell_completion: [
        name: "shell-completion",
        about: "Generate shell completion scripts",
        options: [
          shell: [
            short: "-s",
            long: "--shell",
            help: "Shell type (#{Enum.join(@supported_shells, "/")})",
            default: "bash"
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
    end
  end

  defp get_shell(%{shell: "bash"}), do: {:ok, :bash}
  defp get_shell(_), do: {:error, "Unsupported shell type"}
end
