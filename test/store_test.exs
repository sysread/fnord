defmodule StoreTest do
  use Fnord.TestCase, async: false

  setup do: {:ok, project: mock_project("blarg")}

  test "store_home/0", %{home_dir: home} do
    fnord_home = Path.join(home, ".fnord")
    assert fnord_home == Store.store_home()
  end
end
