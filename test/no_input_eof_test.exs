defmodule ExCmd.NoInputEOFTest do
  use ExUnit.Case, async: true

  @moduletag os: :unix

  for status <- [0, 1, 23] do
    @status status
    test "no-input stdout reaches exit #{@status}" do
      status = @status

      task =
        Task.async(fn ->
          try do
            chunks =
              ExCmd.stream!([
                "/bin/sh",
                "-c",
                ~S(if IFS= read -r unused; then exit 97; fi; printf payload; exit "$1"),
                "no-input",
                Integer.to_string(status)
              ])
              |> Enum.to_list()

            {:ok, chunks}
          rescue
            error in ExCmd.Stream.AbnormalExit -> {:exit, error.exit_status}
          end
        end)

      try do
        expected = if status == 0, do: {:ok, ["payload"]}, else: {:exit, status}
        assert Task.await(task) == expected
      after
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end
    end
  end
end
