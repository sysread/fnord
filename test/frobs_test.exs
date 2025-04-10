defmodule FrobsTest do
  use Fnord.TestCase

  setup do
    mock_project("blarg")

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

    %{temp_home: temp_home}
  end

  test "creates, validates, loads, and runs a frob", %{temp_home: home} do
    # Create it
    assert {:ok, %Frobs{name: "say_hi"} = frob} = Frobs.create("say_hi")

    # Should return spec + registry parsed, path set
    assert frob.home == Path.join([home, "fnord", "tools", "say_hi"])
    assert frob.spec["name"] == "say_hi"
    assert is_map(frob.registry)

    # Run it
    args_json = ~s|{"name":"Alice"}|
    assert {:ok, output} = Frobs.perform_tool_call("say_hi", args_json)

    assert output =~ "Frob invoked from project:"
    assert output =~ "Hello, Alice!"
  end
end
