defmodule ExCmd.ExitStatusStressTest do
  # Run with: mix test --only stress
  use ExUnit.Case, async: false

  @moduletag :stress
  @moduletag os: :unix
  @moduletag timeout: :infinity

  @concurrency 48
  @batch 25

  defp outcome(cmd, opts) do
    ExCmd.stream!(cmd, opts) |> Stream.run()
    :ok
  rescue
    error in ExCmd.Stream.AbnormalExit -> {:exit_status, error.exit_status}
    error in ExCmd.Process.Error -> {:read_error, Exception.message(error)}
  end

  defp outcomes(runs, cmd, opts) do
    1..div(runs, @batch)
    |> Task.async_stream(fn _ -> Enum.map(1..@batch, fn _ -> outcome(cmd, opts) end) end,
      max_concurrency: @concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, results} -> results end)
    |> Enum.frequencies()
  end

  @success ["sh", "-c", "printf 'x\\n'; exit 0"]
  @failure ["sh", "-c", "printf 'x\\n'; exit 3"]
  @slow ["sh", "-c", "printf 'x\\n'; sleep 0.05; printf 'y\\n'; exit 0"]

  test "a successful short command never reports failure" do
    assert outcomes(15_000, @success, []) == %{ok: 15_000}
  end

  test "a successful short command with empty input never reports failure" do
    assert outcomes(15_000, @success, input: []) == %{ok: 15_000}
  end

  test "a failing command always reports its own exit status" do
    assert outcomes(10_000, @failure, []) == %{{:exit_status, 3} => 10_000}
  end

  test "a failing command with empty input always reports its own exit status" do
    assert outcomes(10_000, @failure, input: []) == %{{:exit_status, 3} => 10_000}
  end

  test "a slower command never reports failure" do
    assert outcomes(15_000, @slow, []) == %{ok: 15_000}
  end
end
