defmodule Sprout.Daemon do
  @moduledoc """
  Remote process control for session management on the daemon-node.
  """

  @spec remote() :: node()
  def remote, do: :"sproutd@#{hostname()}"

  @spec create(Sprout.cid()) :: {:ok, Sprout.sid()} | {:error, term()}
  def create(cid) do
    :rpc.call(remote(), Sproutd.Pool, :create, [cid])
  end

  @spec attach(Sprout.sid(), Sprout.cid()) :: :ok | {:error, term()}
  def attach(sid, cid) do
    :rpc.call(remote(), Sproutd.Pool, :attach, [sid, cid])
  end

  @spec leave(Sprout.sid(), Sprout.cid()) :: {:ok, map()} | {:error, term()}
  def leave(sid, cid) do
    :rpc.call(remote(), Sproutd.Pool, :leave, [sid, cid])
  end

  defp hostname do
    :inet.gethostname() |> elem(1) |> to_string()
  end
end
