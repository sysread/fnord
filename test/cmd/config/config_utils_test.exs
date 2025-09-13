defmodule Cmd.Config.UtilsTest do
  use Fnord.TestCase

  alias Cmd.Config.Utils

  describe "require_key/4" do
    test "returns value from opts when present" do
      opts = %{foo: "from_opts"}
      args = ["from_args"]
      assert {:ok, "from_opts"} = Utils.require_key(opts, args, :foo, "Foo")
    end

    test "returns first arg when opts missing" do
      opts = %{}
      args = ["first_arg", "second_arg"]
      assert {:ok, "first_arg"} = Utils.require_key(opts, args, :foo, "Foo")
    end

    test "opts takes precedence over args" do
      opts = %{foo: "opt_value"}
      args = ["arg_value"]
      assert {:ok, "opt_value"} = Utils.require_key(opts, args, :foo, "Foo")
    end

    test "returns error when neither opts nor args present" do
      opts = %{}
      args = []
      assert {:error, msg} = Utils.require_key(opts, args, :foo, "Foo")
      assert msg == "Foo is required. Provide Foo as positional argument or --foo."
    end
  end
end
