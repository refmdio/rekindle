defmodule Rekindle.Toolchain.FrameTest do
  use ExUnit.Case, async: true

  alias Rekindle.Toolchain.{Frame, Handshake}

  @request "0123456789abcdef0123456789abcdef"

  test "round-trips canonical partial frames and preserves remaining bytes" do
    header = %{"type" => "stdout", "request_id" => @request, "sequence" => 0, "eof" => false}
    assert {:ok, encoded} = Frame.encode(header, <<0, 1, 2>>)
    assert {:more, _} = Frame.decode(binary_part(encoded, 0, 3))
    assert {:ok, decoded, <<0, 1, 2>>, "tail"} = Frame.decode(encoded <> "tail")
    assert decoded["payload_len"] == 3
    assert decoded["v"] == 1
  end

  test "rejects noncanonical, duplicate-key, oversized, and malformed frames" do
    noncanonical = ~s({"v":1, "type":"x","request_id":"#{@request}","payload_len":0})

    assert {:error, :noncanonical_header} =
             Frame.decode(<<byte_size(noncanonical)::32, noncanonical::binary>>)

    duplicate = ~s({"payload_len":0,"request_id":"#{@request}","type":"x","type":"x","v":1})

    assert {:error, :noncanonical_header} =
             Frame.decode(<<byte_size(duplicate)::32, duplicate::binary>>)

    assert {:error, :header_too_large} = Frame.decode(<<65_537::32>>)
    assert {:error, :invalid_frame} = Frame.encode(%{"type" => "x", "request_id" => "bad"})
  end

  test "hello admission binds nonce, mode, host, and every compatibility value" do
    actual = actual()
    host = %{"os" => "linux", "arch" => "x86_64"}
    hello = Handshake.hello("exec-v1", actual, host)

    assert :ok = Handshake.validate_hello(hello, "exec-v1", actual, host)
    response = Handshake.hello_ok(hello, actual, host)
    assert :ok = Handshake.admit_response(response, hello)

    assert {:error, :nonce_mismatch} =
             Handshake.admit_response(
               %{response | "session_nonce" => String.duplicate("0", 64)},
               hello
             )

    assert {:error, :version_mismatch} =
             Handshake.admit_response(
               put_in(response, ["actual", "helper_version"], "other"),
               hello
             )
  end

  defp actual do
    %{
      "helper_version" => "0.1.0",
      "toolframe" => 1,
      "exec_protocol" => 1,
      "web_protocol" => 1,
      "wasm_bindgen_schema" => "0.2.121",
      "web_manifest" => 1,
      "native_manifest" => 1
    }
  end
end
