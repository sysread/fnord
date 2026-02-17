defmodule FrobsTest do
  use Fnord.TestCase, async: false

  setup do
    mock_project("blarg")
    :ok
  end

  test "creates, validates, loads, and runs a frob", %{home_dir: home} do
    # Create it
    assert {:ok, %Frobs{name: "say_hi"} = frob} = Frobs.create("say_hi")

    # Should return spec parsed, path set
    assert frob.home == Path.join([home, "fnord", "tools", "say_hi"])
    assert frob.spec.name == "say_hi"

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
      assert {"Calling frob 'hello_test'", _details} = mod.ui_note_on_request(args)
      assert {"Frob 'hello_test' result", _details} = mod.ui_note_on_result(args, result)
    end

    test "negative path rejects missing required args via centralized validation" do
      assert {:ok, frob} = Frobs.create("hello_neg")
      mod = Frobs.create_tool_module(frob)
      tools = %{"hello_neg" => mod}

      # The default frob spec requires "name". Omitting it should be caught by
      # AI.Tools.Params.validate_json_args in the perform_tool_call pipeline.
      assert {:error, :missing_argument, msg} =
               AI.Tools.perform_tool_call("hello_neg", %{}, tools)

      assert msg =~ "name"
    end
  end

  # Helper to write a custom spec and executable main for a frob
  defp write_frob!(home, name, spec_json) do
    path = Path.join([home, "fnord", "tools", name])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "spec.json"), spec_json)
    File.write!(Path.join(path, "main"), "#!/bin/bash\necho ok")
    File.chmod!(Path.join(path, "main"), 0o755)
    path
  end

  describe "validation" do
    test "fails to load frob with invalid JSON spec", %{home_dir: home} do
      path = Path.join([home, "fnord", "tools", "bad_frob"])
      File.mkdir_p!(path)
      File.write!(Path.join(path, "spec.json"), "{ not valid json ")

      File.write!(Path.join(path, "main"), "#!/bin/bash\necho ok")
      File.chmod!(Path.join(path, "main"), 0o755)

      assert {:error, :invalid_json, _} = Frobs.load("bad_frob")
    end

    test "fails when spec is missing name", %{home_dir: home} do
      path = Path.join([home, "fnord", "tools", "broken_frob"])
      File.mkdir_p!(path)

      File.write!(Path.join(path, "spec.json"), ~s|{
        "description": "oops",
        "parameters": { "type": "object", "properties": {} }
      }|)

      File.write!(Path.join(path, "main"), "#!/bin/bash\necho ok")
      File.chmod!(Path.join(path, "main"), 0o755)

      assert {:error, :invalid_structure, _} = Frobs.load("broken_frob")
    end

    test "fails to load frob with non-executable main", %{home_dir: home} do
      assert {:ok, _frob} = Frobs.create("no_exec")
      File.chmod!(Path.join([home, "fnord", "tools", "no_exec", "main"]), 0o644)

      assert {:error, :not_executable} = Frobs.load("no_exec")
    end

    test "fails if required field is not in properties", %{home_dir: home} do
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

      File.write!(Path.join(path, "main"), "#!/bin/bash\necho ok")
      File.chmod!(Path.join(path, "main"), 0o755)

      assert {:error, :missing_required_keys, _} = Frobs.load("field_mismatch")
    end

    test "loads frob with anyOf property", %{home_dir: home} do
      write_frob!(home, "any_of_frob", ~s|{
        "name": "any_of_frob",
        "description": "Uses anyOf",
        "parameters": {
          "type": "object",
          "required": ["val"],
          "properties": {
            "val": {
              "description": "A string or integer",
              "anyOf": [{"type": "string"}, {"type": "integer"}]
            }
          }
        }
      }|)

      assert {:ok, %Frobs{name: "any_of_frob"}} = Frobs.load("any_of_frob")
    end

    test "loads frob with oneOf property", %{home_dir: home} do
      write_frob!(home, "one_of_frob", ~s|{
        "name": "one_of_frob",
        "description": "Uses oneOf",
        "parameters": {
          "type": "object",
          "required": ["val"],
          "properties": {
            "val": {
              "description": "A string or null",
              "oneOf": [{"type": "string"}, {"type": "null"}]
            }
          }
        }
      }|)

      assert {:ok, %Frobs{name: "one_of_frob"}} = Frobs.load("one_of_frob")
    end

    test "loads frob with allOf property", %{home_dir: home} do
      write_frob!(home, "all_of_frob", ~s|{
        "name": "all_of_frob",
        "description": "Uses allOf",
        "parameters": {
          "type": "object",
          "required": ["val"],
          "properties": {
            "val": {
              "description": "Composed schema",
              "allOf": [
                {"type": "object", "properties": {"a": {"type": "string", "description": "a"}}},
                {"properties": {"b": {"type": "integer", "description": "b"}}}
              ]
            }
          }
        }
      }|)

      assert {:ok, %Frobs{name: "all_of_frob"}} = Frobs.load("all_of_frob")
    end

    test "loads frob with both type and oneOf", %{home_dir: home} do
      write_frob!(home, "both_frob", ~s|{
        "name": "both_frob",
        "description": "Has type and oneOf",
        "parameters": {
          "type": "object",
          "required": ["val"],
          "properties": {
            "val": {
              "type": "object",
              "description": "Has both type and oneOf",
              "oneOf": [
                {"type": "object", "properties": {"a": {"type": "string", "description": "a"}}},
                {"type": "object", "properties": {"b": {"type": "string", "description": "b"}}}
              ]
            }
          }
        }
      }|)

      assert {:ok, %Frobs{name: "both_frob"}} = Frobs.load("both_frob")
    end

    test "fails when anyOf is not a list", %{home_dir: home} do
      write_frob!(home, "bad_anyof", ~s|{
        "name": "bad_anyof",
        "description": "Bad anyOf",
        "parameters": {
          "type": "object",
          "required": ["val"],
          "properties": {
            "val": {
              "description": "Bad",
              "anyOf": "not a list"
            }
          }
        }
      }|)

      assert {:error, :invalid_composition, _} = Frobs.load("bad_anyof")
    end

    test "fails when anyOf is empty", %{home_dir: home} do
      write_frob!(home, "empty_anyof", ~s|{
        "name": "empty_anyof",
        "description": "Empty anyOf",
        "parameters": {
          "type": "object",
          "required": ["val"],
          "properties": {
            "val": {
              "description": "Empty",
              "anyOf": []
            }
          }
        }
      }|)

      assert {:error, :invalid_composition, _} = Frobs.load("empty_anyof")
    end

    test "loads frob with omitted required field (defaults to empty)", %{home_dir: home} do
      write_frob!(home, "no_required", ~s|{
        "name": "no_required",
        "description": "No required field",
        "parameters": {
          "type": "object",
          "properties": {
            "val": {
              "type": "string",
              "description": "Optional value"
            }
          }
        }
      }|)

      assert {:ok, %Frobs{name: "no_required"}} = Frobs.load("no_required")
    end

    test "fails when required is not a list", %{home_dir: home} do
      write_frob!(home, "bad_required_type", ~s|{
        "name": "bad_required_type",
        "description": "Bad required",
        "parameters": {
          "type": "object",
          "required": "not_a_list",
          "properties": {
            "val": {
              "type": "string",
              "description": "A value"
            }
          }
        }
      }|)

      assert {:error, :invalid_required_type, _} = Frobs.load("bad_required_type")
    end

    test "fails when required contains non-strings", %{home_dir: home} do
      write_frob!(home, "bad_required_entries", ~s|{
        "name": "bad_required_entries",
        "description": "Bad required entries",
        "parameters": {
          "type": "object",
          "required": [123],
          "properties": {
            "val": {
              "type": "string",
              "description": "A value"
            }
          }
        }
      }|)

      assert {:error, :invalid_required_entries, _} = Frobs.load("bad_required_entries")
    end

    test "fails when description is empty", %{home_dir: home} do
      write_frob!(home, "empty_desc", ~s|{
        "name": "empty_desc",
        "description": "Nonempty top-level",
        "parameters": {
          "type": "object",
          "properties": {
            "val": {
              "type": "string",
              "description": ""
            }
          }
        }
      }|)

      assert {:error, :missing_description, _} = Frobs.load("empty_desc")
    end

    test "fails when property description is missing", %{home_dir: home} do
      write_frob!(home, "no_prop_desc", ~s|{
        "name": "no_prop_desc",
        "description": "Has top-level desc",
        "parameters": {
          "type": "object",
          "properties": {
            "val": {
              "type": "string"
            }
          }
        }
      }|)

      assert {:error, :missing_description, _} = Frobs.load("no_prop_desc")
    end

    test "fails when tool name does not match directory name", %{home_dir: home} do
      write_frob!(home, "dir_name", ~s|{
        "name": "wrong_name",
        "description": "Mismatched name",
        "parameters": {
          "type": "object",
          "properties": {
            "val": {
              "type": "string",
              "description": "A value"
            }
          }
        }
      }|)

      assert {:error, :name_mismatch, _} = Frobs.load("dir_name")
    end

    test "fails when top-level description is empty", %{home_dir: home} do
      write_frob!(home, "empty_top_desc", ~s|{
        "name": "empty_top_desc",
        "description": "   ",
        "parameters": {
          "type": "object",
          "properties": {
            "val": {
              "type": "string",
              "description": "A value"
            }
          }
        }
      }|)

      assert {:error, :empty_description, _} = Frobs.load("empty_top_desc")
    end

    test "fails when property is not a JSON object", %{home_dir: home} do
      write_frob!(home, "prop_not_obj", ~s|{
        "name": "prop_not_obj",
        "description": "Bad property",
        "parameters": {
          "type": "object",
          "properties": {
            "val": "not_an_object"
          }
        }
      }|)

      assert {:error, :invalid_property, _} = Frobs.load("prop_not_obj")
    end

    test "fails when property has invalid type", %{home_dir: home} do
      write_frob!(home, "bad_type", ~s|{
        "name": "bad_type",
        "description": "Invalid type",
        "parameters": {
          "type": "object",
          "properties": {
            "val": {
              "type": "banana",
              "description": "Bad type"
            }
          }
        }
      }|)

      assert {:error, :invalid_type, _} = Frobs.load("bad_type")
    end

    test "fails when composition entries are not objects", %{home_dir: home} do
      write_frob!(home, "bad_comp_entries", ~s|{
        "name": "bad_comp_entries",
        "description": "Bad composition entries",
        "parameters": {
          "type": "object",
          "properties": {
            "val": {
              "description": "Bad entries",
              "anyOf": ["not_an_object", "also_not"]
            }
          }
        }
      }|)

      assert {:error, :invalid_composition, _} = Frobs.load("bad_comp_entries")
    end

    test "fails when property has no type or composition keyword", %{home_dir: home} do
      write_frob!(home, "no_type", ~s|{
        "name": "no_type",
        "description": "No type",
        "parameters": {
          "type": "object",
          "required": ["val"],
          "properties": {
            "val": {
              "description": "Missing type and composition"
            }
          }
        }
      }|)

      assert {:error, :missing_type, msg} = Frobs.load("no_type")
      assert msg =~ "anyOf, oneOf, allOf"
      assert msg =~ "$ref/$defs are not currently supported"
    end
  end
end
