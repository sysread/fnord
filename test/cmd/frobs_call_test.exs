defmodule Cmd.FrobsCallTest do
  use Fnord.TestCase, async: false

  setup do
    set_log_level(:none)
    {:ok, project: mock_project("frobs_call_proj")}
  end

  # Helper: creates a frob with a custom spec and executable main
  defp write_frob!(home, name, spec_json) do
    path = Path.join([home, "fnord", "tools", name])
    File.mkdir_p!(path)

    File.write!(Path.join(path, "spec.json"), spec_json)

    File.write!(Path.join(path, "main"), """
    #!/usr/bin/env bash
    echo "Hello, $(jq -r '.name' <<< "$FNORD_ARGS_JSON")!"
    """)

    File.chmod!(Path.join(path, "main"), 0o755)
  end

  test "call invokes frob using defaults in non-interactive mode", %{home_dir: home} do
    name = "call_test_frob"

    write_frob!(home, name, ~s|{
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
    }|)

    Settings.Frobs.enable(:global, name)

    {stdout, _stderr} =
      capture_all(fn ->
        Cmd.Frobs.run(%{name: name, project: "frobs_call_proj"}, [:call], [])
      end)

    assert stdout =~ "Hello, Alice!"
  end

  # Cannot test the negative path through run/3 because UI.fatal calls
  # System.halt(1), which kills the VM. Instead, test the same sequence that
  # call_frob executes: load → prompt → validate. This exercises the full
  # validation pipeline without hitting the fatal exit.
  test "call rejects missing required args with no defaults", %{home_dir: home} do
    name = "call_neg_frob"

    write_frob!(home, name, ~s|{
      "name": "#{name}",
      "description": "Neg test frob",
      "parameters": {
        "type": "object",
        "required": ["name"],
        "properties": {
          "name": {
            "type": "string",
            "description": "The name"
          }
        }
      }
    }|)

    Settings.Frobs.enable(:global, name)

    assert {:ok, frob} = Frobs.load(name)

    # In non-interactive mode (quiet: true in tests), prompt_for_params fails
    # on required params with no defaults -- the same path call_frob takes.
    assert {:error, {:non_interactive_missing_required, ["name"]}} =
             Frobs.Prompt.prompt_for_params(frob.spec, UI)
  end
end
