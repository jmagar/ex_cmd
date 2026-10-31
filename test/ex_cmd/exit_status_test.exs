defmodule ExCmd.ExitStatusTest do
  use ExUnit.Case, async: true

  alias ExCmd.Process
  alias ExCmd.Process.Proto

  require Proto

  @moduletag os: :unix

  # A port dies as soon as a write to it fails, and whatever it has not read
  # yet is lost with it. odu must therefore stay reachable until the port is
  # closed, or a late write can discard an exit status that is already in the
  # pipe.
  test "odu keeps stdin open after reporting the exit status" do
    Elixir.Process.flag(:trap_exit, true)

    {_os_pid, port} =
      Proto.start([System.find_executable("sh"), "-c", "exit 3"], [], %{stderr: :disable})

    odu_pid = port |> Port.info(:os_pid) |> elem(1)

    {:error, :eagain} = Proto.read(port, 100)
    assert_receive {^port, {:data, <<Proto.output_eof()>>}}, 5000
    assert_receive {^port, {:data, <<Proto.exit_status(), 3::big-signed-integer-32>>}}, 5000

    :ok = Proto.close(port, :stdin)
    :ok = Proto.kill(port)

    refute_receive {^port, {:exit_status, _}}, 200
    refute_received {:EXIT, ^port, _}
    assert Port.info(port) != nil
    assert os_process_alive?(odu_pid)

    Port.close(port)
    assert_receive {:EXIT, ^port, :normal}, 5000
    assert os_process_exits?(odu_pid)
  end

  test "closing a pipe after the exit status keeps the status" do
    {:ok, process} = Process.start_link(["sh", "-c", "exit 3"])
    port = :sys.get_state(process.pid).port
    ref = Port.monitor(port)

    assert :eof = Process.read(process)
    assert_receive {:DOWN, ^ref, :port, ^port, :normal}, 5000

    assert :ok = Process.close_stdin(process)
    assert {:ok, 3} = Process.await_exit(process)
    refute_received {_exit_ref, {:error, _}}
  end

  test "the port is released once the exit status arrives, without await_exit" do
    {:ok, process} = Process.start_link(["true"])
    port = :sys.get_state(process.pid).port
    ref = Port.monitor(port)

    assert :eof = Process.read(process)
    assert_receive {:DOWN, ^ref, :port, ^port, :normal}, 5000

    assert {:ok, 0} = Process.await_exit(process)
  end

  test "stream reports the exit status when the input owner exits with the command" do
    assert ["x", {:exit, {:status, 3}}] =
             ExCmd.stream(["sh", "-c", "printf x; exit 3"], input: []) |> Enum.to_list()
  end

  test "a read cut short by the death of odu is still an error" do
    {:ok, process} = Process.start_link(["sleep", "60"])
    %{port: port, os_pid: command_pid} = :sys.get_state(process.pid)
    odu_pid = port |> Port.info(:os_pid) |> elem(1)

    on_exit(fn ->
      System.cmd("kill", ["-KILL", to_string(command_pid)], stderr_to_stdout: true)
    end)

    parent = self()

    reader =
      Task.async(fn ->
        :ok = Process.change_pipe_owner(process, :stdout, self())
        send(parent, :reading)
        Process.read(process)
      end)

    assert_receive :reading, 5000
    wait_for_pending_read(process)

    {_, 0} = System.cmd("kill", ["-KILL", to_string(odu_pid)])

    assert {:error, :epipe} = Task.await(reader)
    assert {:error, :port_abnormal_exit} = Process.await_exit(process, 500)
  end

  defp wait_for_pending_read(process, attempts \\ 500) do
    cond do
      :sys.get_state(process.pid).operations.read_stdout != nil ->
        :ok

      attempts == 0 ->
        flunk("read never became pending")

      true ->
        :timer.sleep(10)
        wait_for_pending_read(process, attempts - 1)
    end
  end

  defp os_process_exits?(pid, attempts \\ 500) do
    cond do
      !os_process_alive?(pid) ->
        true

      attempts == 0 ->
        false

      true ->
        :timer.sleep(10)
        os_process_exits?(pid, attempts - 1)
    end
  end

  defp os_process_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))
  end
end
