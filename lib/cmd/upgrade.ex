defmodule Cmd.Upgrade do
  @behaviour Cmd

  @impl Cmd
  def spec do
    [
      upgrade: [
        name: "upgrade",
        about: "Upgrade fnord to the latest version",
        flags: [
          yes: [
            long: "--yes",
            short: "-y",
            help: "Automatically answer 'yes' to all prompts",
            default: false
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts) do
    if confirm(opts) do
      System.cmd("mix", ["escript.install", "--force", "github", "sysread/fnord"],
        stderr_to_stdout: true,
        into: IO.stream(:stdio, :line)
      )
    else
      IO.puts("Cancelled")
    end
  end

  defp confirm(%{yes: true}), do: true

  defp confirm(_opts) do
    IO.write("Do you want to upgrade to the latest version of fnord? (y/n) ")

    case IO.gets("") do
      "y\n" -> true
      "Y\n" -> true
      _ -> false
    end
  end
end
