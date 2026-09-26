defmodule Sprout do
  @moduledoc false

  @type cid :: String.t()
  @type sid :: String.t()

  @spec client_dir() :: Path.t()
  def client_dir do
    dir = Path.join(System.tmp_dir!(), "sprout-#{ProcessTree.get(:cid)}")
    File.mkdir_p!(dir)
    dir
  end

  @spec socket_path() :: Path.t()
  def socket_path, do: Path.join(client_dir(), "socket")

  @spec pipe_path() :: Path.t()
  def pipe_path, do: Path.join(client_dir(), "pipe.fifo")

  @spec relay_path() :: Path.t()
  def relay_path, do: Path.join(client_dir(), "relay.fifo")

  @spec env_path() :: Path.t()
  def env_path, do: Path.join(client_dir(), "env")

  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cost: non_neg_integer(),
          duration: non_neg_integer()
        }

  @usage_keys ~w(input_tokens output_tokens total_tokens cost duration)a

  @spec empty_usage() :: usage()
  def empty_usage, do: Map.new(@usage_keys, &{&1, 0})
end