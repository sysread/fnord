defmodule Cmd.FrobsCallTest do
  use Fnord.TestCase, async: false

  setup do
    set_log_level(:none)
    {:ok, project: mock_project("frobs_call_proj")}
  end

  test "call invokes frob using defaults in non-interactive mode", %{home_dir: home} do
    name = "call_test_frob"

    # Write a custom spec with a default so prompting succeeds non-interactively
    path = Path.join([home, "fnord", "tools", name])
    File.mkdir_p!(path)

    File.write!(
      Path.join(path, "spec.json"),
      ~s|{
        "name": "#{name}",
        "description": "Test frob",
        "parameters": {
          "type": "object",
          "required": ["name"],
          "properties": {
            "name": {
              "type": "string",
              "description": "The name",
              "default": "Alice"
            }
          }
        }
      }|
    )

    File.write!(Path.join(path, "main"), """
    #!/usr/bin/env bash
    echo "Hello, $(jq -r '.name' <<< "$FNORD_ARGS_JSON")!"
    """)

    File.chmod!(Path.join(path, "main"), 0o755)

    Settings.Frobs.enable(:global, name)

    {stdout, _stderr} =
      capture_all(fn ->
        Cmd.Frobs.run(%{name: name, project: "frobs_call_proj"}, [:call], [])
      end)

    assert stdout =~ "Hello, Alice!"
  end
end
