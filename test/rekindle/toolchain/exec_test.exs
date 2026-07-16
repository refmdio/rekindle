defmodule Rekindle.Toolchain.ExecTest do
  use ExUnit.Case, async: true

  alias Rekindle.Toolchain.Exec

  @request "0123456789abcdef0123456789abcdef"

  test "constructs one closed absolute argv/environment spawn request" do
    assert {:ok, header, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: "/usr/bin/printf",
               argv: ["%s", "hello world"],
               cwd: "/tmp",
               env_mode: :replace,
               env_set: [{"Z", "2"}, {"A", "1"}],
               env_unset: ["OLD"],
               terminate_grace_ms: 10,
               kill_grace_ms: 20
             )

    assert state.request_id == @request
    assert header["executable"] == %{"kind" => "path", "value" => "/usr/bin/printf"}
    assert header["argv"] == ["%s", "hello world"]
    assert header["env_mode"] == "replace"
    assert header["env_set"] == [["A", "1"], ["Z", "2"]]
    assert {:ok, _encoded} = Exec.encode(header)

    assert {:error, :invalid_spawn} = Exec.spawn_request(executable: "printf", cwd: "/tmp")
    assert {:error, :invalid_spawn} = Exec.spawn_request(executable: "/bin/x", cwd: "relative")

    assert {:error, :invalid_spawn} =
             Exec.spawn_request(
               executable: "/bin/x",
               cwd: "/tmp",
               env_set: [{"A", "1"}, {"A", "2"}]
             )

    assert {:error, :invalid_spawn} =
             Exec.spawn_request(
               executable: "/bin/x",
               cwd: "/tmp",
               env_set: [{"A", "1"}],
               env_unset: ["A"]
             )
  end

  test "malformed environment entries fail closed without raising or producing a request" do
    malformed_env_set = [
      [:bad],
      [{"A"}],
      [{"A", "1", "extra"}],
      [{"A", 1}],
      [{1, "value"}],
      [{"A", "value\0suffix"}],
      [{"A", <<255>>}],
      [{"A", "1"} | :improper]
    ]

    for env_set <- malformed_env_set do
      assert {:error, :invalid_spawn} =
               Exec.spawn_request(
                 executable: "/bin/echo",
                 cwd: "/tmp",
                 env_set: env_set
               )
    end

    for env_unset <- [[1], ["A", "A"], ["A" | :improper]] do
      assert {:error, :invalid_spawn} =
               Exec.spawn_request(
                 executable: "/bin/echo",
                 cwd: "/tmp",
                 env_unset: env_unset
               )
    end

    assert {:error, :invalid_spawn} =
             Exec.spawn_request(
               executable: "/bin/echo",
               cwd: "/tmp",
               argv: ["ok" | :improper]
             )
  end

  test "admits independently sequenced bounded byte streams and terminal exit" do
    state = state()
    assert {:ok, state} = Exec.accept(state, started(), <<>>)
    assert {:ok, state} = Exec.accept(state, stream("stderr", 0, false, 3), "err")
    assert {:ok, state} = Exec.accept(state, stream("stdout", 0, false, 3), "out")
    assert {:ok, state} = Exec.accept(state, stream("stdout", 1, true, 0), <<>>)
    assert {:ok, state} = Exec.accept(state, stream("stderr", 1, true, 0), <<>>)

    assert {:terminal, result, terminal} = Exec.accept(state, exit(3, 3), <<>>)

    assert result == %{
             outcome: :exited,
             code: 0,
             signal: nil,
             cleanup: :confirmed,
             stdout_bytes: 3,
             stderr_bytes: 3,
             discarded_stdout: 0,
             discarded_stderr: 0
           }

    assert {:error, :post_terminal_frame} =
             Exec.accept(terminal, stream("stdout", 2, true, 0), <<>>)
  end

  test "rejects duplicate, gapped, reordered, and missing EOF streams" do
    assert {:ok, state} = Exec.accept(state(), started(), <<>>)
    assert {:error, :stream_sequence} = Exec.accept(state, stream("stdout", 1, false, 1), "x")

    assert {:ok, state} = Exec.accept(state, stream("stdout", 0, true, 0), <<>>)
    assert {:error, :stream_after_eof} = Exec.accept(state, stream("stdout", 1, true, 0), <<>>)
    assert {:error, :missing_stream_eof} = Exec.accept(state, exit(0, 0), <<>>)
  end

  test "admits spawn failure and all idempotent cancellation reasons" do
    state = state()
    spawn_failed = exit(0, 0) |> Map.merge(%{"outcome" => "spawn_failed", "code" => nil})
    assert {:terminal, %{outcome: :spawn_failed}, _} = Exec.accept(state, spawn_failed, <<>>)

    for reason <- [:obsolete, :timeout, :shutdown, :caller] do
      assert {:ok, %{"type" => "cancel", "reason" => encoded}} = Exec.cancel(state, reason)
      assert encoded == Atom.to_string(reason)
    end

    assert {:error, :invalid_cancel} = Exec.cancel(state, :other)
  end

  test "classifies signal and uncertain cleanup without losing counters" do
    assert {:ok, state} = Exec.accept(state(), started(), <<>>)
    assert {:ok, state} = Exec.accept(state, stream("stdout", 0, true, 4), "data")
    assert {:ok, state} = Exec.accept(state, stream("stderr", 0, true, 0), <<>>)

    terminal =
      exit(4, 0)
      |> Map.merge(%{
        "outcome" => "signaled",
        "code" => nil,
        "signal" => 9,
        "cleanup" => "uncertain",
        "discarded_stdout" => 8
      })

    assert {:terminal, %{outcome: :signaled, signal: 9, cleanup: :uncertain, discarded_stdout: 8},
            _} =
             Exec.accept(state, terminal, <<>>)
  end

  defp state do
    {:ok, _header, state} =
      Exec.spawn_request(request_id: @request, executable: "/bin/echo", cwd: "/tmp")

    state
  end

  defp started do
    %{
      "v" => 1,
      "type" => "started",
      "request_id" => @request,
      "payload_len" => 0,
      "pid" => 123,
      "process_group" => 123
    }
  end

  defp stream(type, sequence, eof, length) do
    %{
      "v" => 1,
      "type" => type,
      "request_id" => @request,
      "payload_len" => length,
      "sequence" => sequence,
      "eof" => eof
    }
  end

  defp exit(stdout, stderr) do
    %{
      "v" => 1,
      "type" => "exit",
      "request_id" => @request,
      "payload_len" => 0,
      "outcome" => "exited",
      "code" => 0,
      "signal" => nil,
      "cleanup" => "confirmed",
      "stdout_bytes" => stdout,
      "stderr_bytes" => stderr,
      "discarded_stdout" => 0,
      "discarded_stderr" => 0
    }
  end
end
