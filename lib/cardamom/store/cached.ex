defmodule Cardamom.Store.Cached do
  @moduledoc """
  The transferable Nebulex + SQLite read-through pattern, factored out so caching is
  STRUCTURAL — a store gets it by using this, not by hand-copying `read_through` + a
  `Cache.put`/`Cache.delete` per table (the copy-paste that left mempool edges uncached).

  Two shapes, both backed by `Cardamom.Store.Cache` (Nebulex) over `Cardamom.Store.Repo`:

    * PK-keyed ROW (`new/1`): one entity by primary key. `get/2` read-through, `put/2`
      write-through, `invalidate/2`. Cache key: `{cache_tag, key_tuple}`.
    * list-by-secondary-key (`new_list/1`): a LIST loaded by some key (e.g. mempool edges
      by input). `get_list/2` read-through, `invalidate_key/2` to drop one key's list.
      Writes/deletes don't go through here (they vary); the caller invalidates the
      affected keys. Cache key: `{cache_tag, :list, key}`.

  nil results are NOT cached (a genuine absence must not pin a negative entry — the next
  write should be visible).
  """

  alias Cardamom.Store.{Cache, Repo}

  @enforce_keys [:cache_tag]
  defstruct [:cache_tag, :schema, :key_fields, :load]

  @type t :: %__MODULE__{}

  # ---- PK-keyed row ----

  @doc "A PK-keyed cached store over `schema`, keyed by `key_fields` (in order)."
  def new(opts) do
    %__MODULE__{
      cache_tag: Keyword.fetch!(opts, :cache_tag),
      schema: Keyword.fetch!(opts, :schema),
      key_fields: Keyword.fetch!(opts, :key_fields)
    }
  end

  @doc "Read-through get by key (a single value or a tuple matching key_fields)."
  def get(%__MODULE__{} = s, key) do
    read_through({s.cache_tag, key}, fn -> Repo.get_by(s.schema, kw(s, key)) end)
  end

  @doc "Write-through put: insert/upsert the row AND cache it under its key."
  def put(%__MODULE__{} = s, row) do
    key = key_of(s, row)

    {:ok, stored} =
      Repo.insert(row, on_conflict: :replace_all, conflict_target: s.key_fields)

    Cache.put({s.cache_tag, key}, stored)
    {:ok, stored}
  end

  @doc "Drop the cache entry for `key` (e.g. after a direct mutate) so the next get re-reads."
  def invalidate(%__MODULE__{} = s, key), do: Cache.delete({s.cache_tag, key})

  # ---- list-by-secondary-key ----

  @doc "A list-shaped cached store: `load.(key)` returns the list for a secondary key."
  def new_list(opts) do
    %__MODULE__{
      cache_tag: Keyword.fetch!(opts, :cache_tag),
      load: Keyword.fetch!(opts, :load)
    }
  end

  @doc "Read-through get of the list for `key`."
  def get_list(%__MODULE__{load: load} = s, key) when is_function(load, 1) do
    case Cache.get({s.cache_tag, :list, key}) do
      nil ->
        list = load.(key)
        # An empty list IS a valid cached result here (unlike a nil row miss): the list
        # query is total. Cache it; callers invalidate the key on any write touching it.
        Cache.put({s.cache_tag, :list, key}, list)
        list

      list ->
        list
    end
  end

  @doc "Invalidate the cached list for `key` (call when a member is added/removed)."
  def invalidate_key(%__MODULE__{} = s, key), do: Cache.delete({s.cache_tag, :list, key})

  # ---- internals ----

  # key may be a bare value (single key_field) or a tuple matching key_fields in order.
  defp kw(%{key_fields: [f]}, key) when not is_tuple(key), do: [{f, key}]

  defp kw(%{key_fields: fields}, key) when is_tuple(key) do
    Enum.zip(fields, Tuple.to_list(key))
  end

  defp key_of(%{key_fields: [f]}, row), do: Map.fetch!(row, f)

  defp key_of(%{key_fields: fields}, row),
    do: fields |> Enum.map(&Map.fetch!(row, &1)) |> List.to_tuple()

  defp read_through(cache_key, fetch_fn) do
    case Cache.get(cache_key) do
      nil ->
        case fetch_fn.() do
          nil -> nil
          val -> Cache.put(cache_key, val) && val
        end

      val ->
        val
    end
  end
end
