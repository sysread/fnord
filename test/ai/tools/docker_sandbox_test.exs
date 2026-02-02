defmodule AI.Tools.DockerSandboxTest do
  use Fnord.TestCase, async: false
  @tag mox: [DockerSandbox.CLI.Mock]
  setup do
    original_docker_cli = Application.get_env(:fnord, :docker_cli)
    Application.put_env(:fnord, :docker_cli, DockerSandbox.CLI.Mock)

    on_exit(fn ->
      case original_docker_cli do
        nil -> Application.delete_env(:fnord, :docker_cli)
        _ -> Application.put_env(:fnord, :docker_cli, original_docker_cli)
      end
    end)

    :ok
  end

  test "spec defines actions and parameters" do
    spec = AI.Tools.DockerSandbox.spec()
    assert spec.name == "docker_sandbox_tool"
    assert Map.has_key?(spec.parameters.properties, "action")
  end

  test "is_available? false when docker missing" do
    expect(DockerSandbox.CLI.Mock, :executable?, fn "docker" -> false end)
    refute AI.Tools.DockerSandbox.is_available?()
  end

  test "read_args/1 rejects missing action" do
    assert {:error, _} = AI.Tools.DockerSandbox.read_args(%{})
  end

  test "read_args/1 rejects missing required fields for run" do
    assert {:error, _} = AI.Tools.DockerSandbox.read_args(%{"action" => "run"})
  end
end
