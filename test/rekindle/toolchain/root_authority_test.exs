defmodule Rekindle.Toolchain.RootAuthorityTest do
  use ExUnit.Case, async: false

  alias Rekindle.Toolchain.RootAuthority

  setup do
    assert_eventually(fn -> RootAuthority.stats() == %{authorities: 0, leases: 0} end)
    :ok
  end

  test "an unleased registration is removed when its issuer exits" do
    key = key(:unused)
    identity = identity(1)

    task = Task.async(fn -> RootAuthority.register(key, identity) end)
    assert :ok == Task.await(task)
    assert_eventually(fn -> RootAuthority.fetch(key) == {:error, :unknown_authority} end)
    assert RootAuthority.stats() == %{authorities: 0, leases: 0}
  end

  test "multi-root leases are atomic and reject identity changes" do
    first = key(:first)
    second = key(:second)
    first_identity = identity(1)
    second_identity = identity(2)

    assert :ok = RootAuthority.register(first, first_identity)
    assert :ok = RootAuthority.register(second, second_identity)

    assert {:error, :identity_changed} =
             RootAuthority.lease([{first, first_identity}, {second, identity(9)}])

    assert RootAuthority.stats() == %{authorities: 2, leases: 0}

    assert {:ok, lease} =
             RootAuthority.lease([{first, first_identity}, {second, second_identity}])

    assert RootAuthority.leased?(lease)
    assert {:error, :identity_changed} = RootAuthority.register(first, identity(9))
    assert :ok = RootAuthority.release(lease)
    refute RootAuthority.leased?(lease)
    assert RootAuthority.stats() == %{authorities: 0, leases: 0}
  end

  test "concurrent leases retain shared roots until the final release" do
    first = key(:shared_first)
    second = key(:shared_second)
    entries = [{first, identity(1)}, {second, identity(2)}]

    Enum.each(entries, fn {key, identity} ->
      assert :ok = RootAuthority.register(key, identity)
    end)

    assert {:ok, local_lease} = RootAuthority.lease(entries)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, remote_lease} = RootAuthority.lease(entries)
        send(parent, {:leased, self(), remote_lease})

        receive do
          :release ->
            assert :ok = RootAuthority.release(remote_lease)
            send(parent, {:released, self()})
        end
      end)

    assert_receive {:leased, ^owner, remote_lease}
    assert RootAuthority.stats() == %{authorities: 2, leases: 2}
    assert :ok = RootAuthority.release(local_lease)
    assert RootAuthority.stats() == %{authorities: 2, leases: 1}
    assert {:ok, identity} = RootAuthority.fetch(first)
    assert identity == identity(1)
    assert RootAuthority.leased?(remote_lease)

    send(owner, :release)
    assert_receive {:released, ^owner}
    assert_eventually(fn -> RootAuthority.stats() == %{authorities: 0, leases: 0} end)
  end

  test "lease owner exit releases active authority and explicit release is transferable" do
    exit_key = key(:owner_exit)
    exit_identity = identity(1)
    assert :ok = RootAuthority.register(exit_key, exit_identity)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} = RootAuthority.lease([{exit_key, exit_identity}])
        send(parent, {:leased, self(), lease})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:leased, ^owner, _lease}
    send(owner, :exit)
    assert_eventually(fn -> RootAuthority.stats() == %{authorities: 0, leases: 0} end)

    release_key = key(:transfer_release)
    release_identity = identity(2)
    assert :ok = RootAuthority.register(release_key, release_identity)
    assert {:ok, lease} = RootAuthority.lease([{release_key, release_identity}])
    task = Task.async(fn -> RootAuthority.release(lease) end)
    assert :ok == Task.await(task)
    assert RootAuthority.stats() == %{authorities: 0, leases: 0}
    assert :ok = RootAuthority.release(lease)
  end

  defp key(label), do: {__MODULE__, label, make_ref()}

  defp identity(number) do
    %{
      inode: number,
      uid: number,
      gid: number,
      major_device: number,
      minor_device: number,
      type: :directory,
      mode: 0o40700
    }
  end

  defp assert_eventually(assertion, attempts \\ 100)

  defp assert_eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp assert_eventually(assertion, 0), do: assert(assertion.())
end
