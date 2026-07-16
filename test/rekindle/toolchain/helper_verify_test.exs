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

  test "accepts one exact helper hello and closes the verification process", %{root: root} do
    ports = MapSet.new(Port.list())
    assert :ok = Helper.verify(helper!(root, "valid"), timeout_ms: 1_000)
    assert ports == MapSet.new(Port.list())
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

    length_bytes = sys.stdin.buffer.read(4)
    if len(length_bytes) != 4:
        sys.exit(2)
    length = struct.unpack(">I", length_bytes)[0]
    hello = json.loads(sys.stdin.buffer.read(length))

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
    if kind == "mode": mode = "exec-v1"

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

    encoded = json.dumps(response, sort_keys=True, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(struct.pack(">I", len(encoded)) + encoded)
    sys.stdout.buffer.flush()
    time.sleep(2)
    """)

    File.chmod!(path, 0o700)
    path
  end
end
