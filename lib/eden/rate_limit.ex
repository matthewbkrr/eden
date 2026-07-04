defmodule Eden.RateLimit do
  @moduledoc """
  A small in-memory **fixed-window** rate limiter (#236) — no external dependency,
  in the spirit of the project's other hand-rolled pieces (`Eden.Tokens`,
  `Eden.Storage.SigV4`).

  A GenServer owns one **public** ETS table; callers hit it directly with an atomic
  `:ets.update_counter/4`, so throttling never funnels through the process (no
  bottleneck). Each `(key, window)` bucket counts requests in a `scale_ms` window;
  buckets carry their own expiry and a periodic sweep drops the stale ones, so the
  table can't grow without bound.

  Fixed-window (not sliding/token-bucket) is the deliberate trade: it's a handful of
  lines, allocation-free per hit, and precise enough for a login/invite throttle at
  this scale. The only cost is a burst allowance of up to `2 * limit` across a window
  boundary, which doesn't matter for perimeter hardening.

  Interface — the whole surface:

      Eden.RateLimit.hit({:login, ip}, :timer.minutes(5), 10)
      #=> :ok | {:error, :rate_limited}

  `key` is any term (a `{scope, ip}` tuple in practice); `scale_ms` is the window
  length; `limit` is the max hits allowed per window. The `limit + 1`-th hit in a
  window returns `{:error, :rate_limited}`.
  """
  use GenServer

  @table __MODULE__
  @sweep_interval :timer.minutes(1)

  @doc "Starts the limiter — owns the ETS table and periodically sweeps stale buckets."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records one hit against `key` in the current `scale_ms` window. Returns `:ok`
  while at or under `limit`, `{:error, :rate_limited}` once the window's count
  exceeds it. Atomic and lock-free (a single `:ets.update_counter/4`).
  """
  @spec hit(term(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def hit(key, scale_ms, limit)
      when is_integer(scale_ms) and scale_ms > 0 and is_integer(limit) and limit > 0 do
    now = System.system_time(:millisecond)
    window = div(now, scale_ms)
    bucket = {key, window}
    # The bucket lives until the end of its window; the sweep uses this to GC.
    expires_at = (window + 1) * scale_ms
    count = :ets.update_counter(@table, bucket, {2, 1}, {bucket, 0, expires_at})
    if count > limit, do: {:error, :rate_limited}, else: :ok
  end

  @doc false
  # Test/ops helper: forget every bucket for a key's scope by clearing the table.
  # Not used in the request path.
  def reset_all, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    # Drop every bucket whose window has already ended (expires_at < now).
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
