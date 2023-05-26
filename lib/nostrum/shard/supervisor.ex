defmodule Nostrum.Shard.Supervisor do
  @moduledoc """
  Supervises shard processes.

  ## Implementation

  As events are sent to the shard, the following happens:

  1. Shard looks to see what type of event it is, only dispatch events are sent
     to the producer.

  2. If the event is a `Dispatch`, the payload is converted to an atom-keyed map.
     This is done because over ETF (which Nostrum uses), map keys are sometimes
     binaries and sometimes strings, making it a real headache. Additionally,
     with atom keys, we can use the `Map.key` notation. This is normally
     considered unsafe but a debug messages will be emitted if a key is unsafely
     converted to an atom. In this way we can ensure that our atom table is not
     growing unbounded.

  3. The payload is then written to the cache. To make sure we're not overrunning
     the cache, especially at startup with `request_guild_members` or other heavy
     payloads, this is done in the shard itself. 

  4. The cache updates itself from the new data. In some cases, such as update or
     delete events, it may send out a second "old" object as well, that helps the
     library user to determine what changed.

  5. After writing to the cache, the shard `send`s out the event after going
     through the cache to all subscribed processes. In general, the payload will
     often match the payload described by the official Discord API documentation.

  6. The shard instructs the websocket client that it's ready to read more data.
     This prevents flooding the shard with messages that it may not be able to
     handle yet, thus growing the message queue and the memory usage.
  """

  use Supervisor

  alias Nostrum.Error.CacheError
  alias Nostrum.Shard
  alias Nostrum.Shard.Session
  alias Nostrum.Store.GuildShardMapping
  alias Nostrum.Util

  require Logger

  defp cast_shard_range(gateway_shards, :auto), do: {1, gateway_shards, gateway_shards}
  defp cast_shard_range(gateway_shards, gateway_shards), do: {1, gateway_shards, gateway_shards}

  defp cast_shard_range(gateway_shards, count) when is_integer(count) and count > 0 do
    Logger.warn(
      "Configured shard count (#{count}) " <>
        "differs from Discord Gateway's recommended shard count (#{gateway_shards}). " <>
        "Consider using `num_shards: :auto` option in your Nostrum config."
    )

    {1, count, count}
  end

  defp cast_shard_range(_gateway_shards, {lowest, highest, total} = range)
       when is_integer(lowest) and is_integer(highest) and is_integer(total) and
              lowest <= highest and highest <= total do
    range
  end

  def start_link(_args) do
    {url, gateway_shard_count} = Util.gateway()

    value = Application.get_env(:nostrum, :num_shards, :auto)
    shard_range = cast_shard_range(gateway_shard_count, value)

    Supervisor.start_link(
      __MODULE__,
      [url, shard_range],
      name: __MODULE__
    )
  end

  def update_status(status, game, stream, type) do
    __MODULE__
    |> Supervisor.which_children()
    |> Enum.filter(fn {_id, _pid, _type, [modules]} -> modules == Nostrum.Shard end)
    |> Enum.map(fn {_id, pid, _type, _modules} -> Supervisor.which_children(pid) end)
    |> List.flatten()
    |> Enum.map(fn {_id, pid, _type, _modules} ->
      Session.update_status(pid, status, game, stream, type)
    end)
  end

  def update_voice_state(guild_id, channel_id, self_mute, self_deaf) do
    case GuildShardMapping.get(guild_id) do
      nil ->
        raise CacheError, key: guild_id, cache_name: GuildShardMapping

      shard_num ->
        :"Nostrum.Shard-#{shard_num}"
        |> Supervisor.which_children()
        |> Enum.find(fn {id, _pid, _type, _modules} -> id == Nostrum.Shard.Session end)
        |> elem(1)
        |> Session.update_voice_state(guild_id, channel_id, self_mute, self_deaf)
    end
  end

  @doc false
  def init([url, {lowest, highest, total}]) do
    shard_range = lowest..highest
    children = for num <- shard_range, do: create_worker(url, num - 1, total)

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end

  @doc false
  def create_worker(gateway, shard_num, total) do
    Supervisor.child_spec(
      {Shard, [gateway, shard_num, total]},
      id: shard_num
    )
  end
end
