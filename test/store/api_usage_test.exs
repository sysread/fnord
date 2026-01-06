defmodule Store.APIUsageTest do
  use Fnord.TestCase, async: false

  defp usage_path(), do: Store.APIUsage.store_path()

  defp read_usage_file!() do
    usage_path()
    |> File.read!()
    |> Jason.decode!()
  end

  test "record_for_model/2 creates the store file (if missing) and persists rate limit headers keyed by model" do
    refute File.exists?(usage_path())

    response = %HTTPoison.Response{
      status_code: 200,
      headers: [
        {"x-ratelimit-limit-requests", "100"},
        {"x-ratelimit-remaining-requests", "99"},
        {"x-ratelimit-reset-requests", "2ms"},
        {"x-ratelimit-limit-tokens", "1000"},
        {"x-ratelimit-remaining-tokens", "900"},
        {"x-ratelimit-reset-tokens", "1s"}
      ],
      body: ~s({"model":"ignored-because-header-wins"})
    }

    assert {:ok, ^response} = Store.APIUsage.record_for_model("gpt-4o-mini", {:ok, response})
    assert File.exists?(usage_path())

    data = read_usage_file!()

    assert %{
             "updated_at" => updated_at,
             "requests_max" => 100,
             "requests_left" => 99,
             "requests_reset" => 2,
             "tokens_max" => 1000,
             "tokens_left" => 900,
             "tokens_reset" => 1000
           } = Map.fetch!(data, "gpt-4o-mini")

    assert is_integer(updated_at)
    assert updated_at > 0
  end

  test "record_for_model/2 accepts float reset headers and stores integer milliseconds" do
    refute File.exists?(usage_path())

    response = %HTTPoison.Response{
      status_code: 200,
      headers: [
        {"x-ratelimit-limit-requests", "10"},
        {"x-ratelimit-remaining-requests", "5"},
        {"x-ratelimit-reset-requests", "1.043s"},
        {"x-ratelimit-limit-tokens", "100"},
        {"x-ratelimit-remaining-tokens", "50"},
        {"x-ratelimit-reset-tokens", "0.5s"}
      ],
      body: ~s({})
    }

    assert {:ok, ^response} = Store.APIUsage.record_for_model("gpt-4o-mini", {:ok, response})
    data = read_usage_file!()

    assert %{
             "requests_reset" => 1043,
             "tokens_reset" => 500
           } = Map.fetch!(data, "gpt-4o-mini")
  end

  test "record_for_model/2 creates the store file but leaves it empty when usage headers are missing" do
    refute File.exists?(usage_path())

    response = %HTTPoison.Response{
      status_code: 200,
      headers: [],
      body: "{}"
    }

    assert {:ok, ^response} = Store.APIUsage.record_for_model("gpt-4o-mini", {:ok, response})
    assert File.exists?(usage_path())

    # No required rate-limit headers were present, so store should remain unchanged.
    assert %{} = read_usage_file!()
  end

  test "record_for_model/2 is a no-op when model is nil" do
    refute File.exists?(usage_path())

    response = %HTTPoison.Response{
      status_code: 200,
      headers: [],
      body: "{}"
    }

    assert Store.APIUsage.record_for_model(nil, {:ok, response}) == {:ok, response}
    refute File.exists?(usage_path())
  end

  test "record_for_model/2 is a no-op for non-2xx responses" do
    refute File.exists?(usage_path())

    response = %HTTPoison.Response{
      status_code: 429,
      headers: [],
      body: "{}"
    }

    assert Store.APIUsage.record_for_model("gpt-4o-mini", {:ok, response}) == {:ok, response}
    refute File.exists?(usage_path())
  end

  test "check/1 creates the store file when missing" do
    refute File.exists?(usage_path())

    # With no prior usage recorded, we should be allowed to request immediately.
    assert :ok = Store.APIUsage.check("gpt-4o-mini")
    assert File.exists?(usage_path())
  end

  test "check/1 returns {:wait, ms} when the reset window has not elapsed" do
    File.mkdir_p!(Path.dirname(usage_path()))

    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    File.write!(
      usage_path(),
      Jason.encode!(%{
        "gpt-4o-mini" => %{
          "updated_at" => now,
          "requests_max" => 100,
          "requests_left" => 0,
          "requests_reset" => 10_000,
          "tokens_max" => 1000,
          "tokens_left" => 0,
          "tokens_reset" => 10_000
        }
      })
    )

    assert {:wait, wait_ms} = Store.APIUsage.check("gpt-4o-mini")
    assert is_integer(wait_ms)
    assert wait_ms > 0
    assert wait_ms <= 10_000
  end

  test "check/1 returns :ok when the reset window has elapsed" do
    File.mkdir_p!(Path.dirname(usage_path()))

    # If updated_at is far in the past, elapsed_time will exceed requests_reset.
    File.write!(
      usage_path(),
      Jason.encode!(%{
        "gpt-4o-mini" => %{
          "updated_at" => 0,
          "requests_max" => 100,
          "requests_left" => 0,
          "requests_reset" => 1,
          "tokens_max" => 1000,
          "tokens_left" => 0,
          "tokens_reset" => 1
        }
      })
    )

    assert :ok = Store.APIUsage.check("gpt-4o-mini")
  end
end
