defmodule Sproutd.Pool do
  @moduledoc false

  require Logger

  defp generate_sid do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  @spec create(Sprout.cid()) :: {:ok, Sprout.sid()} | {:error, term()}
  def create(cid) do
    reset_group_leader()

    sid = generate_sid()
    child = {Sproutd.Session, {sid, cid}}

    with {:ok, _pid} <- DynamicSupervisor.start_child(__MODULE__, child) do
      Logger.info("session #{sid} created", sid: sid, cid: cid)
      {:ok, sid}
    end
  end

  @spec attach(Sprout.sid(), Sprout.cid()) :: :ok | {:error, :not_found}
  def attach(sid, cid) do
    reset_group_leader()

    if pid = GenServer.whereis(Sproutd.Session.via(sid)) do
      GenServer.cast(pid, {:attach, cid})
      Logger.info("client #{cid} attached to session #{sid}", sid: sid, cid: cid)
      :ok
    else
      Logger.warning("client #{cid} attempted to attach to unknown session #{sid}", sid: sid, cid: cid)
      {:error, :not_found}
    end
  end

  @spec leave(Sprout.sid(), Sprout.cid()) :: {:ok, Sprout.usage()} | {:error, :not_found}
  def leave(sid, cid) do
    reset_group_leader()

    if pid = GenServer.whereis(Sproutd.Session.via(sid)) do
      Logger.info("client #{cid} left session #{sid}", sid: sid, cid: cid)

      {:ok, GenServer.call(pid, {:leave, cid})}
    else
      Logger.warning("client #{cid} attempted to leave unknown session #{sid}", sid: sid, cid: cid)

      {:error, :not_found}
    end
  end

  defp reset_group_leader do
    # :rpc.call/4 (used by Sprout.Daemon) passes the caller's group leader to
    # the called code, which routes our own I/O (eg. Logger) to the calling
    # node's console instead of ours. This prevents leaking those internal logs.

    :erlang.group_leader(Process.whereis(:user), self())
  end

  @doc false
  def child_spec(opts) do
    opts
    |> Keyword.put(:name, __MODULE__)
    |> Keyword.put_new(:strategy, :one_for_one)
    |> DynamicSupervisor.child_spec()
  end
end