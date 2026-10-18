defmodule ExCmd.StreamCauseTest do
  use ExUnit.Case, async: false

  defp command do
    ExCmd.stream!(["sh", "-c", "printf ready; exec cat"])
  end

  defp track_child do
    {:links, links} = Process.info(self(), :links)

    child =
      Enum.find(links, fn pid ->
        is_pid(pid) && match?({:dictionary, _}, Process.info(pid, :dictionary)) &&
          Keyword.get(elem(Process.info(pid, :dictionary), 1), :"$initial_call") ==
            {ExCmd.Process, :init, 1}
      end)

    assert is_pid(child)
    state = :sys.get_state(child)
    send(self(), {:owned_child, child, state.os_pid, Process.monitor(child)})
    child
  end

  defp assert_reaped do
    assert_received {:owned_child, child, os_pid, monitor}
    assert_receive {:DOWN, ^monitor, :process, ^child, _}, 2000
    refute Process.alive?(child)
    assert {_, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    assert status != 0
  end

  test "an actual Process.read closed-pipe error survives cleanup with its stack" do
    try do
      Enum.reduce(command(), nil, fn _chunk, _acc ->
        child = track_child()
        assert :ok = ExCmd.Process.close_stdout(%ExCmd.Process{pid: child})
        nil
      end)

      flunk("read must fail")
    rescue
      error in ExCmd.Process.Error ->
        assert Exception.message(error) =~ "pipe_closed_or_invalid_caller"

        assert Enum.any?(__STACKTRACE__, fn {mod, fun, _, _} ->
                 mod == Enumerable.ExCmd.Stream && fun == :read_next
               end)
    end

    assert_reaped()
  end

  test "a consumer exception survives cleanup with the consumer frame" do
    try do
      Enum.reduce(command(), nil, fn _, _ ->
        track_child()
        raise ArgumentError, "original consumer failure"
      end)

      flunk("consumer must fail")
    rescue
      error in ArgumentError ->
        assert Exception.message(error) == "original consumer failure"
        assert Enum.any?(__STACKTRACE__, fn {mod, _, _, _} -> mod == __MODULE__ end)
    end

    assert_reaped()
  end

  test "a consumer throw survives cleanup" do
    reason = {:consumer_abort, make_ref()}

    assert catch_throw(
             Enum.reduce(command(), nil, fn _, _ ->
               track_child()
               throw(reason)
             end)
           ) == reason

    assert_reaped()
  end

  test "a consumer exit survives cleanup" do
    assert catch_exit(
             Enum.reduce(command(), nil, fn _, _ ->
               track_child()
               exit(:original_consumer_exit)
             end)
           ) == :original_consumer_exit

    assert_reaped()
  end

  test "suspended reductions resume and close without losing output" do
    stream = ExCmd.stream!(["printf", "abcd"], max_chunk_size: 1)
    reducer = fn item, acc -> {:suspend, [item | acc]} end
    assert {:suspended, ["a"], resume} = Enumerable.reduce(stream, {:cont, []}, reducer)
    assert {:suspended, ["b", "a"], resume} = resume.({:cont, ["a"]})
    assert {:suspended, ["c", "b", "a"], resume} = resume.({:cont, ["b", "a"]})
    assert {:suspended, ["d", "c", "b", "a"], resume} = resume.({:cont, ["c", "b", "a"]})
    assert {:halted, ["d", "c", "b", "a"]} = resume.({:cont, ["d", "c", "b", "a"]})
  end

  test "initial halt and suspend retain the existing resource contract" do
    stream = ExCmd.stream!(["printf", "ready"], ignore_epipe: true)

    assert {:halted, :untouched} =
             Enumerable.reduce(stream, {:halt, :untouched}, fn _, _ -> flunk() end)

    assert {:suspended, [], resume} =
             Enumerable.reduce(stream, {:suspend, []}, fn item, acc -> {:cont, [item | acc]} end)

    assert {:halted, ["ready"]} = resume.({:cont, []})
  end

  test "normal EOF and nonzero command status retain their contracts" do
    assert Enum.to_list(ExCmd.stream!(["printf", "complete"])) == ["complete"]

    assert_raise ExCmd.Stream.AbnormalExit, "program exited with exit status: 7", fn ->
      Enum.to_list(ExCmd.stream!(["sh", "-c", "printf done; exit 7"]))
    end
  end

  test "intentional early halt and ignored broken pipe retain their contracts" do
    assert_raise ExCmd.Stream.AbnormalExit, ~r/epipe/, fn ->
      command()
      |> Stream.map(fn chunk ->
        track_child()
        chunk
      end)
      |> Enum.take(1)
    end

    assert_reaped()

    assert [_] =
             ExCmd.stream!(["cat"], input: Stream.cycle(["data"]), ignore_epipe: true)
             |> Enum.take(1)

    assert_raise ExCmd.Stream.AbnormalExit, ~r/epipe/, fn ->
      ExCmd.stream!(["cat"], input: Stream.cycle(["data"])) |> Enum.take(1)
    end
  end
end
