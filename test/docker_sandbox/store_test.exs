defmodule DockerSandbox.StoreTest do
  use Fnord.TestCase, async: false

  setup do
    proj = mock_project("demo")
    {:ok, proj: proj}
  end

  test "root_path contains tools/sandboxes", %{proj: proj} do
    path = DockerSandbox.Store.root_path(proj)
    assert String.ends_with?(path, Path.join(["tools", "sandboxes"]))
  end

  test "CRUD lifecycle and round-trips dockerfile_body + default_run_args", %{proj: proj} do
    assert DockerSandbox.Store.list(proj) == []

    {:ok, stored} =
      DockerSandbox.Store.put(proj, %{
        name: "test1",
        description: "desc",
        dockerfile_body: "RUN echo hi\n",
        default_run_args: ["sh", "-lc", "echo ok"]
      })

    assert stored["name"] == "test1"
    assert stored["description"] == "desc"
    assert stored["dockerfile_body"] == "RUN echo hi\n"
    assert stored["default_run_args"] == ["sh", "-lc", "echo ok"]

    [entry] = DockerSandbox.Store.list(proj)
    assert entry.name == "test1"
    assert entry.description == "desc"
    assert is_binary(entry.updated_at)

    {:ok, fetched} = DockerSandbox.Store.get(proj, "test1")
    assert fetched["name"] == "test1"
    assert fetched["description"] == "desc"
    assert fetched["dockerfile_body"] == "RUN echo hi\n"
    assert fetched["default_run_args"] == ["sh", "-lc", "echo ok"]

    :ok = DockerSandbox.Store.delete(proj, "test1")
    assert DockerSandbox.Store.list(proj) == []
    assert DockerSandbox.Store.get(proj, "test1") == {:error, :not_found}
  end
end
