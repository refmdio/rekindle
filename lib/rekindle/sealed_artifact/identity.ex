defmodule Rekindle.SealedArtifact.Identity do
  @moduledoc false

  alias Rekindle.CanonicalValue

  @safe_integer 9_007_199_254_740_991
  @web_member_keys ~w[path role sha256 size]
  @desktop_executable_keys ~w[mode path sha256 size]

  @spec derive(Rekindle.target(), map()) :: {:ok, String.t()} | :error
  def derive(:web, manifest) do
    with %{"build" => %{"build_key" => build_key}, "members" => members} <- manifest,
         true <- digest?(build_key),
         true <- is_list(members) and members != [],
         {:ok, members} <- web_members(members) do
      {:ok,
       digest(
         "rekindle-web-artifact-v2\0",
         %{"v" => 2, "build_key" => build_key, "members" => members}
       )}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def derive(:desktop, manifest) do
    with %{
           "build" => %{"build_key" => build_key},
           "executable" => executable
         } <- manifest,
         true <- digest?(build_key),
         {:ok, executable} <- desktop_executable(executable) do
      {:ok,
       digest(
         "rekindle-native-artifact-v2\0",
         %{"v" => 2, "build_key" => build_key, "executable" => executable}
       )}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def derive(_target, _manifest), do: :error

  defp web_members(members) do
    Enum.reduce_while(members, {:ok, []}, fn member, {:ok, values} ->
      identity = Map.take(member, @web_member_keys)

      if Map.keys(identity) |> Enum.sort() == @web_member_keys and
           nonempty_string?(identity["path"]) and nonempty_string?(identity["role"]) and
           digest?(identity["sha256"]) and uint?(identity["size"]) do
        {:cont, {:ok, [identity | values]}}
      else
        {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp desktop_executable(executable) when is_map(executable) do
    identity = Map.take(executable, @desktop_executable_keys)

    if Map.keys(identity) |> Enum.sort() == @desktop_executable_keys and
         nonempty_string?(identity["path"]) and digest?(identity["sha256"]) and
         uint?(identity["size"]) and nonempty_string?(identity["mode"]),
       do: {:ok, identity},
       else: :error
  end

  defp desktop_executable(_executable), do: :error

  defp digest(domain, value) do
    :crypto.hash(:sha256, domain <> CanonicalValue.encode!(value))
    |> Base.encode16(case: :lower)
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp uint?(value), do: is_integer(value) and value in 0..@safe_integer
end
