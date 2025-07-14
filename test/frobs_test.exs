defmodule FrobsTest do
  use Fnord.TestCase

  setup do
    # ---------------------------------------------------------------------------
    # Override $HOME via the HOME environment variable
    # Fnord uses `System.user_home!/0` which respects HOME
    # ---------------------------------------------------------------------------
    {:ok, temp_home} = Briefly.create(directory: true)
    original_home = System.get_env("HOME")
    System.put_env("HOME", temp_home)

    on_exit(fn ->
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end
    end)

    # Create a mock project
    mock_project("blarg")

    %{temp_home: temp_home}
  end

  test "creates, validates, loads, and runs a frob", %{temp_home: home} do
    # Create it
    assert {:ok, %Frobs{name: "say_hi"} = frob} = Frobs.create("say_hi")

    # Should return spec + registry parsed, path set
    assert frob.home == Path.join([home, "fnord", "tools", "say_hi"])
    assert frob.spec.name == "say_hi"
    assert is_map(frob.registry)

    # Run it
    args_json = ~s|{"name":"Alice"}|
    assert {:ok, output} = Frobs.perform_tool_call("say_hi", args_json)

    assert output =~ "Frob invoked from project: blarg"
    assert output =~ "Project config:"
    assert output =~ "Hello, Alice!"
  end

  describe "AI.Tools integration" do
    test "positive path" do
      # Create the frob and module
      assert {:ok, frob} = Frobs.create("hello_test")
      mod = Frobs.create_tool_module(frob)

      # Confirm module implements AI.Tools behaviour
      assert function_exported?(mod, :spec, 0)
      assert function_exported?(mod, :read_args, 1)
      assert function_exported?(mod, :call, 1)
      assert function_exported?(mod, :ui_note_on_request, 1)
      assert function_exported?(mod, :ui_note_on_result, 2)
      assert function_exported?(mod, :async?, 0)
      assert mod.async?() == true

      # Confirm tool spec is accessible through AI.Tools
      tools = %{"hello_test" => mod}
      spec = AI.Tools.tool_spec!("hello_test", tools)
      assert spec.function.name == "hello_test"
      assert Map.has_key?(spec.function.parameters.properties, :name)

      # Test the tool via AI.Tools.perform_tool_call/3
      args = %{"name" => "TestUser"}
      assert {:ok, result} = AI.Tools.perform_tool_call("hello_test", args, tools)
      assert is_binary(result)
      assert result =~ "Hello, TestUser"

      # Test the UI helpers
      assert {"Calling frob `hello_test`", _details} = mod.ui_note_on_request(args)
      assert {"Frob `hello_test` result", _details} = mod.ui_note_on_result(args, result)
    end
  end

  describe "validation" do
    test "fails to load frob with invalid JSON spec", %{temp_home: home} do
      path = Path.join([home, "fnord", "tools", "bad_frob"])
      File.mkdir_p!(path)
      File.write!(Path.join(path, "spec.json"), "{ not valid json ")
      File.write!(Path.join(path, "registry.json"), ~s|{"global": true}|)

      File.write!(Path.join(path, "main"), "#!/bin/bash\necho ok")
      File.chmod!(Path.join(path, "main"), 0o755)

      assert {:error, :invalid_json, _} = Frobs.load("bad_frob")
    end

    test "fails when spec is missing name", %{temp_home: home} do
      path = Path.join([home, "fnord", "tools", "broken_frob"])
      File.mkdir_p!(path)

      File.write!(Path.join(path, "spec.json"), ~s|{
        "description": "oops",
        "parameters": { "type": "object", "properties": {} }
      }|)

      File.write!(Path.join(path, "registry.json"), ~s|{"global": true}|)
      File.write!(Path.join(path, "main"), "#!/bin/bash\necho ok")
      File.chmod!(Path.join(path, "main"), 0o755)

      assert {:error, :invalid_structure, _} = Frobs.load("broken_frob")
    end

    test "fails to load frob with non-executable main", %{temp_home: home} do
      assert {:ok, _frob} = Frobs.create("no_exec")
      File.chmod!(Path.join([home, "fnord", "tools", "no_exec", "main"]), 0o644)

      assert {:error, :not_executable} = Frobs.load("no_exec")
    end

    test "fails if required field is not in properties", %{temp_home: home} do
      path = Path.join([home, "fnord", "tools", "field_mismatch"])
      File.mkdir_p!(path)

      File.write!(Path.join(path, "spec.json"), ~s|{
        "name": "field_mismatch",
        "description": "Invalid frob",
        "parameters": {
          "type": "object",
          "required": ["oops"],
          "properties": {
            "foo": {
              "type": "string",
              "description": "Something"
            }
          }
        }
      }|)

      File.write!(Path.join(path, "registry.json"), ~s|{"global": true}|)
      File.write!(Path.join(path, "main"), "#!/bin/bash\necho ok")
      File.chmod!(Path.join(path, "main"), 0o755)

      assert {:error, :missing_required_keys, _} = Frobs.load("field_mismatch")
    end
  end
end
