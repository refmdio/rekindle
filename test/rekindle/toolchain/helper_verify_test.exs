defmodule Rekindle.Toolchain.HelperVerifyTest do
  use ExUnit.Case, async: false

  alias Rekindle.Failure
  alias Rekindle.Toolchain.Helper

  setup do
    root =
      Path.join(System.tmp_dir!(), "rekindle-helper-verify-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "accepts one complete helper verification session", %{root: root} do
    ports = MapSet.new(Port.list())
    assert :ok = Helper.verify(helper!(root, "valid"), timeout_ms: 1_000)
    assert ports == MapSet.new(Port.list())
  end

  test "settles every successful verification port before returning", %{root: root} do
    ports = MapSet.new(Port.list())
    helper = helper!(root, "valid")

    for iteration <- 1..50 do
      assert Helper.verify(helper, timeout_ms: 1_000) == :ok, "iteration #{iteration}"
      assert ports == MapSet.new(Port.list()), "iteration #{iteration}"
    end
  end

  test "rejects every compatibility binding mismatch and malformed response", %{root: root} do
    for kind <- ~w[protocol schema version host nonce request mode extra malformed premature] do
      assert {:error, %Failure{code: :helper_protocol_mismatch}} =
               Helper.verify(helper!(root, kind), timeout_ms: 1_000),
             kind
    end
  end

  test "bounds a helper that does not answer hello", %{root: root} do
    started = System.monotonic_time(:millisecond)

    assert {:error, %Failure{code: :helper_protocol_mismatch}} =
             Helper.verify(helper!(root, "timeout"), timeout_ms: 100)

    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "rejects every incomplete or failed post-handshake session", %{root: root} do
    for kind <-
          ~w[post_handshake_exit terminal_failure cleanup_uncertain helper_nonzero post_terminal] do
      assert {:error, %Failure{code: :helper_protocol_mismatch}} =
               Helper.verify(helper!(root, kind), timeout_ms: 1_000),
             kind
    end

    started = System.monotonic_time(:millisecond)

    assert {:error, %Failure{code: :helper_protocol_mismatch}} =
             Helper.verify(helper!(root, "post_handshake_timeout"), timeout_ms: 100)

    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  defp helper!(root, kind) do
    path = Path.join(root, kind)

    File.write!(path, """
    #!/usr/bin/python3
    import json
    import struct
    import sys
    import time

    kind = #{inspect(kind)}

    if kind == "premature":
        sys.exit(0)
    if kind == "timeout":
        time.sleep(2)
        sys.exit(0)

    def read_frame():
        length_bytes = sys.stdin.buffer.read(4)
        if len(length_bytes) != 4:
            return None
        length = struct.unpack(">I", length_bytes)[0]
        header = json.loads(sys.stdin.buffer.read(length))
        payload = sys.stdin.buffer.read(header.get("payload_len", 0))
        if len(payload) != header.get("payload_len", 0):
            return None
        return header

    def write_frame(header):
        encoded = json.dumps(header, sort_keys=True, separators=(",", ":")).encode("utf-8")
        sys.stdout.buffer.write(struct.pack(">I", len(encoded)) + encoded)
        sys.stdout.buffer.flush()

    hello = read_frame()
    if hello is None:
        sys.exit(2)

    if kind == "malformed":
        sys.stdout.buffer.write(struct.pack(">I", 1) + b"{")
        sys.stdout.buffer.flush()
        time.sleep(2)
        sys.exit(0)

    actual = dict(hello["expected"])
    host = dict(hello["host"])
    request_id = hello["request_id"]
    nonce = hello["session_nonce"]
    mode = hello["mode"]

    if kind == "protocol": actual["toolframe"] = 2
    if kind == "schema": actual["wasm_bindgen_schema"] = "0.0.0"
    if kind == "version": actual["helper_version"] = "9.9.9"
    if kind == "host": host["arch"] = "other"
    if kind == "nonce": nonce = "0" * 64
    if kind == "request": request_id = "0" * 32
    if kind == "mode": mode = "web-v1"

    response = {
        "v": 1,
        "type": "hello_ok",
        "request_id": request_id,
        "payload_len": 0,
        "session_nonce": nonce,
        "mode": mode,
        "actual": actual,
        "host": host,
    }
    if kind == "extra": response["extra"] = True

    write_frame(response)

    if kind == "post_handshake_exit":
        sys.exit(2)
    if kind == "post_handshake_timeout":
        time.sleep(2)
        sys.exit(0)

    spawn = read_frame()
    if (spawn is None or spawn.get("type") != "spawn" or
        spawn.get("executable", {}).get("kind") != "path" or
        spawn.get("executable", {}).get("value") not in ["/usr/bin/true", "/bin/true"] or
        spawn.get("argv") != [] or spawn.get("cwd") != "/" or
        spawn.get("env_mode") != "replace" or spawn.get("env_set") != [] or
        spawn.get("env_unset") != [] or spawn.get("terminate_grace_ms") != 0 or
        spawn.get("kill_grace_ms") != 100):
        sys.exit(2)

    operation_id = spawn["request_id"]
    write_frame({
        "v": 1,
        "type": "started",
        "request_id": operation_id,
        "payload_len": 0,
        "pid": 100,
        "process_group": 100,
    })
    write_frame({
        "v": 1,
        "type": "stdout",
        "request_id": operation_id,
        "payload_len": 0,
        "sequence": 0,
        "eof": True,
    })
    write_frame({
        "v": 1,
        "type": "stderr",
        "request_id": operation_id,
        "payload_len": 0,
        "sequence": 0,
        "eof": True,
    })
    write_frame({
        "v": 1,
        "type": "exit",
        "request_id": operation_id,
        "payload_len": 0,
        "outcome": "exited",
        "code": 1 if kind == "terminal_failure" else 0,
        "signal": None,
        "cleanup": "uncertain" if kind == "cleanup_uncertain" else "confirmed",
        "stdout_bytes": 0,
        "stderr_bytes": 0,
        "discarded_stdout": 0,
        "discarded_stderr": 0,
    })

    if kind == "post_terminal":
        write_frame({
            "v": 1,
            "type": "stdout",
            "request_id": operation_id,
            "payload_len": 0,
            "sequence": 1,
            "eof": True,
        })
    if kind == "helper_nonzero":
        sys.exit(2)
    sys.exit(0)
    """)

    File.chmod!(path, 0o700)
    path
  end
end
