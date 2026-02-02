defmodule DockerSandbox.BaseImageTest do
  use Fnord.TestCase, async: true

  test "base_hash produces 64-char lowercase hex" do
    hash = DockerSandbox.BaseImage.base_hash()
    assert String.match?(hash, ~r/^[0-9a-f]{64}$/)
  end

  test "tag includes sha256 and first 12 chars" do
    hash = DockerSandbox.BaseImage.base_hash()
    short = String.slice(hash, 0, 12)
    assert DockerSandbox.BaseImage.tag() == "fnord/sandbox-base:#{short}"
  end
end
