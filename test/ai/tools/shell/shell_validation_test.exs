defmodule AI.Tools.Shell.ValidationTest do
  use Fnord.TestCase, async: false

  describe "read_args/1 validation" do
    test "accepts valid command structure with args" do
      valid_args = %{
        "commands" => [
          %{"command" => "ls", "args" => ["-la"]},
          %{"command" => "grep", "args" => ["pattern", "file.txt"]}
        ],
        "description" => "List files and grep"
      }

      assert {:ok, ^valid_args} = AI.Tools.Shell.read_args(valid_args)
    end

    test "accepts valid command structure without args" do
      valid_args = %{
        "commands" => [
          %{"command" => "ls"},
          %{"command" => "pwd"}
        ],
        "description" => "Simple commands"
      }

      assert {:ok, ^valid_args} = AI.Tools.Shell.read_args(valid_args)
    end

    test "rejects command with args as map instead of list" do
      # This mimics the LLM error that caused the Protocol.UndefinedError
      invalid_args = %{
        "commands" => [
          %{
            "command" => "apply_patch",
            "args" => [
              %{
                "patch" => "*** Begin Patch\n*** Update File: lib/test.ex\n..."
              }
            ]
          }
        ],
        "description" => "Apply patch"
      }

      assert {:error, :invalid_argument, error_msg} = AI.Tools.Shell.read_args(invalid_args)
      assert error_msg =~ "command[0].args must be a list of strings"
    end

    test "rejects command with non-string args" do
      invalid_args = %{
        "commands" => [
          %{"command" => "test", "args" => ["valid", 123, "also_valid"]}
        ],
        "description" => "Mixed arg types"
      }

      assert {:error, :invalid_argument, error_msg} = AI.Tools.Shell.read_args(invalid_args)
      assert error_msg =~ "command[0].args must be a list of strings"
    end

    test "rejects commands field as non-list" do
      invalid_args = %{
        "commands" => %{"command" => "ls"},
        "description" => "Commands as map"
      }

      assert {:error, :invalid_argument, error_msg} = AI.Tools.Shell.read_args(invalid_args)
      assert error_msg =~ "commands must be a list"
    end

    test "rejects missing commands field" do
      invalid_args = %{
        "description" => "No commands field"
      }

      assert {:error, :invalid_argument, error_msg} = AI.Tools.Shell.read_args(invalid_args)
      assert error_msg =~ "missing required field 'commands'"
    end

    test "rejects command with non-string command field" do
      invalid_args = %{
        "commands" => [
          %{"command" => 123, "args" => ["arg1"]}
        ],
        "description" => "Non-string command"
      }

      assert {:error, :invalid_argument, error_msg} = AI.Tools.Shell.read_args(invalid_args)
      assert error_msg =~ "command[0] invalid format: expected {command: string, args: [strings]}"
    end

    test "rejects command with missing command field" do
      invalid_args = %{
        "commands" => [
          %{"args" => ["arg1"]}
        ],
        "description" => "Missing command field"
      }

      assert {:error, :invalid_argument, error_msg} = AI.Tools.Shell.read_args(invalid_args)
      assert error_msg =~ "command[0] invalid format: expected {command: string, args: [strings]}"
    end

    test "provides helpful error messages with command index" do
      invalid_args = %{
        "commands" => [
          # valid
          %{"command" => "ls", "args" => ["-la"]},
          # invalid - map in args
          %{"command" => "grep", "args" => [%{"pattern" => "test"}]},
          # valid
          %{"command" => "pwd"}
        ],
        "description" => "Mixed valid and invalid"
      }

      assert {:error, :invalid_argument, error_msg} = AI.Tools.Shell.read_args(invalid_args)
      assert error_msg =~ "command[1].args must be a list of strings"
    end
  end
end
