defmodule AI.Tools.ShellTest do
  use Fnord.TestCase

  alias AI.Tools.Shell

  test "basics" do
    project = mock_project("blarg")
    mock_source_file(project, "file.txt", "hello world\n")
    mock_source_file(project, "file2.txt", "goodbye world\n")

    args = %{
      "description" => "do stuff",
      "timeout_ms" => 5_000,
      "commands" => [
        %{"command" => "ls", "args" => ["-l", "-a", "-h"]},
        %{"command" => "wc", "args" => ["-l"]}
      ]
    }

    assert {:ok, out} = Shell.call(args)
    assert out |> String.trim() |> String.contains?("5")
  end
end
