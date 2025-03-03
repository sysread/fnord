defmodule StoreTest do
  use Fnord.TestCase

  setup do: set_config(workers: 1, quiet: true)
  setup do: {:ok, project: mock_project("blarg")}

  test "store_home/0", %{home_dir: home} do
    fnord_home = Path.join(home, ".fnord")
    assert fnord_home == Store.store_home()
  end
end
