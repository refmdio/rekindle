defmodule Rekindle.Toolchain.Handshake do
  @moduledoc false

  @hello_keys ~w[v type request_id payload_len session_nonce mode expected host]
  @hello_ok_keys ~w[v type request_id payload_len session_nonce mode actual host]

  @spec hello(String.t(), map(), map()) :: map()
  def hello(mode, expected, host) when mode in ["exec-v1", "web-v1"] do
    %{
      "v" => 1,
      "type" => "hello",
      "request_id" => random_hex(16),
      "payload_len" => 0,
      "session_nonce" => random_hex(32),
      "mode" => mode,
      "expected" => expected,
      "host" => host
    }
  end

  @spec validate_hello(map(), String.t(), map(), map()) :: :ok | {:error, atom()}
  def validate_hello(header, mode, actual, host) do
    cond do
      Map.keys(header) |> Enum.sort() != Enum.sort(@hello_keys) ->
        {:error, :invalid_hello}

      header["type"] != "hello" or header["payload_len"] != 0 ->
        {:error, :invalid_hello}

      header["mode"] != mode ->
        {:error, :protocol_mismatch}

      not Regex.match?(~r/\A[0-9a-f]{64}\z/, header["session_nonce"] || "") ->
        {:error, :invalid_hello}

      header["host"] != host ->
        {:error, :host_mismatch}

      header["expected"] != actual ->
        mismatch(header["expected"], actual)

      true ->
        :ok
    end
  end

  @spec hello_ok(map(), map(), map()) :: map()
  def hello_ok(hello, actual, host) do
    %{
      "v" => 1,
      "type" => "hello_ok",
      "request_id" => hello["request_id"],
      "payload_len" => 0,
      "session_nonce" => hello["session_nonce"],
      "mode" => hello["mode"],
      "actual" => actual,
      "host" => host
    }
  end

  @spec admit_response(map(), map()) :: :ok | {:error, atom()}
  def admit_response(response, hello) do
    cond do
      response["type"] == "hello_error" ->
        {:error, :helper_rejected}

      Map.keys(response) |> Enum.sort() != Enum.sort(@hello_ok_keys) ->
        {:error, :invalid_hello_response}

      response["request_id"] != hello["request_id"] ->
        {:error, :request_mismatch}

      response["session_nonce"] != hello["session_nonce"] ->
        {:error, :nonce_mismatch}

      response["mode"] != hello["mode"] ->
        {:error, :mode_mismatch}

      response["host"] != hello["host"] ->
        {:error, :host_mismatch}

      response["actual"] != hello["expected"] ->
        {:error, :version_mismatch}

      response["payload_len"] != 0 ->
        {:error, :invalid_hello_response}

      true ->
        :ok
    end
  end

  defp mismatch(expected, actual) do
    cond do
      expected["toolframe"] != actual["toolframe"] or
        expected["exec_protocol"] != actual["exec_protocol"] or
          expected["web_protocol"] != actual["web_protocol"] ->
        {:error, :protocol_mismatch}

      expected["wasm_bindgen_schema"] != actual["wasm_bindgen_schema"] or
        expected["web_manifest"] != actual["web_manifest"] or
          expected["native_manifest"] != actual["native_manifest"] ->
        {:error, :schema_mismatch}

      true ->
        {:error, :version_mismatch}
    end
  end

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
end
