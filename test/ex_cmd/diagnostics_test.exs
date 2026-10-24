defmodule ExCmd.DiagnosticsTest do
  @moduledoc "Synthetic env/argv values reach the child but must never enter launcher diagnostics."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias ExCmd.Process, as: Command
  alias ExCmd.Process.Exec

  @env_value "SYNTHETIC_EXCMD_ENV_NOT_A_CREDENTIAL"
  @arg_value "SYNTHETIC_EXCMD_ARG_NOT_A_CREDENTIAL"
  @moduletag :tmp_dir

  setup do
    previous = Application.fetch_env(:ex_cmd, :enable_debug_logs)
    previous_level = Logger.get_module_level(ExCmd.Log)
    Logger.put_module_level(ExCmd.Log, :debug)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ex_cmd, :enable_debug_logs, value)
        :error -> Application.delete_env(:ex_cmd, :enable_debug_logs)
      end

      case previous_level do
        [{ExCmd.Log, level}] -> Logger.put_module_level(ExCmd.Log, level)
        [] -> Logger.delete_module_level(ExCmd.Log)
      end
    end)

    :ok
  end

  defp start_command(options \\ []) do
    {:ok, command} =
      Command.start_link(
        ["sh", "-c", "cat", @arg_value],
        Keyword.merge([env: [{"EX_CMD_SYNTHETIC", @env_value}], stderr: :disable], options)
      )

    on_exit(fn ->
      if Process.alive?(command.pid), do: GenServer.stop(command.pid, :normal, 1000)
    end)

    command
  end

  defp assert_private(text) do
    refute text =~ @env_value
    refute text =~ @arg_value
  end

  test "state inspection and OTP status omit private launch arguments" do
    command = start_command()
    state = :sys.get_state(command.pid)
    assert state.args.env == [{"EX_CMD_SYNTHETIC", @env_value}]
    assert_private(inspect(state, limit: :infinity))
    assert_private(inspect(:sys.get_status(command.pid), limit: :infinity))
    assert :ok = Command.close_stdin(command)
    assert {:ok, 0} = Command.await_exit(command, 1000)
  end

  test "real GenServer crash report omits private launch arguments" do
    command = start_command()
    Process.unlink(command.pid)

    log =
      capture_log(fn ->
        try do
          GenServer.call(
            command.pid,
            :synthetic_unhandled_message,
            1000
          )
        catch
          :exit, _ -> :ok
        end
      end)

    assert log =~ "terminating"
    assert_private(log)
  end

  test "real debug lifecycle omits env and argument values" do
    Application.put_env(:ex_cmd, :enable_debug_logs, true)

    log =
      capture_log([level: :debug], fn ->
        command = start_command()
        assert :ok = Command.write(command, "roundtrip")
        assert {:ok, bytes} = Command.read(command, 9)
        assert IO.iodata_to_binary(bytes) == "roundtrip"
        assert :ok = Command.close_stdin(command)
        assert :eof = Command.read(command)
        assert {:ok, 0} = Command.await_exit(command, 1000)
      end)

    assert log =~ "state:"
    assert_private(log)
  end

  test "private environment and arguments still reach the child unchanged" do
    output =
      ExCmd.stream!(["sh", "-c", ~S(printf '%s|%s' "$EX_CMD_SYNTHETIC" "$0"), @arg_value],
        env: [{"EX_CMD_SYNTHETIC", @env_value}]
      )
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert output == @env_value <> "|" <> @arg_value
  end

  test "validation errors omit argument and option values" do
    assert {:error, message} =
             Exec.normalize_exec_args(["cat", @arg_value, nil], [])

    assert_private(message)

    assert {:error, message} =
             Exec.normalize_exec_args(["cat"], unexpected: @env_value)

    assert_private(message)
  end
end
