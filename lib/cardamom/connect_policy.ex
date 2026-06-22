defmodule Cardamom.ConnectPolicy do
  @moduledoc """
  Pure connection-rate policy — POLITENESS by construction. Governs how OFTEN we
  may dial an endpoint, NOT how fast messages flow (chain-sync is pull-bound; the
  relay paces messages — we can't flood it that way). This guards the real
  citizenship risk: reconnecting too often. (We dialed the Preview relay 4x in
  25min and got a connect-timeout — likely rate-limited. This stops that.)

  Time is passed in explicitly (`now_ms:`) so the policy is pure and testable; the
  managing process supplies the real clock.

  Per endpoint it enforces:
    * a minimum **cooldown** between connections (no back-to-back sessions),
    * exponential **backoff** on consecutive failures (don't hammer a failing relay),
    * a **circuit breaker**: after `max_failures` consecutive failures, a long
      block before any further attempt.
  A successful connection resets the failure/backoff state.
  """

  # base_backoff_ms matches the real node's `repromoteErrorDelay = 10` (seconds) from
  # ouroboros-network/lib/Ouroboros/Network/Diffusion/Policies.hs — the delay before a
  # peer is re-dialed AFTER AN ERROR. The reference node keeps that delay flat because it
  # rotates across ~50-100 peers; we hammer a SINGLE relay, so we grow it exponentially
  # on top (cooldown_ms is our own floor for redialing after a *clean* teardown — the
  # reference node has no analogue because it keeps the connection up rather than redialing).
  defstruct cooldown_ms: 30_000,
            base_backoff_ms: 10_000,
            max_backoff_ms: 300_000,
            max_failures: 5,
            breaker_ms: 600_000,
            # per-endpoint state: %{endpoint => %{last_attempt, failures, breaker_until}}
            eps: %{}

  @type endpoint :: {String.t(), non_neg_integer()}

  def new(opts \\ []), do: struct(__MODULE__, opts)

  @doc """
  May we connect to `endpoint` at `now_ms`? Returns `{:ok, policy}` (go, attempt
  recorded) or `{:wait, ms, policy}` (wait `ms` more). Pass `now_ms:`.
  """
  def allow(%__MODULE__{} = p, endpoint, opts) do
    now = Keyword.fetch!(opts, :now_ms)
    st = ep_state(p, endpoint)

    next = next_allowed(p, st)

    cond do
      # circuit breaker open. nil = not tripped (a numeric sentinel like 0 is unsafe:
      # the monotonic clock can be NEGATIVE, so `0 > now` would falsely trip it).
      is_integer(st.breaker_until) and st.breaker_until > now ->
        {:wait, st.breaker_until - now, p}

      # never attempted → allowed now
      next == :never ->
        {:ok, put_ep(p, endpoint, %{st | last_attempt: now})}

      # within backoff/cooldown window since last attempt
      next > now ->
        {:wait, next - now, p}

      true ->
        {:ok, put_ep(p, endpoint, %{st | last_attempt: now})}
    end
  end

  @doc "Record a successful connection (resets failures/backoff)."
  def connected(%__MODULE__{} = p, endpoint, opts) do
    now = Keyword.fetch!(opts, :now_ms)
    put_ep(p, endpoint, %{ep_state(p, endpoint) | failures: 0, breaker_until: nil, last_attempt: now})
  end

  @doc "Record a disconnection (no penalty; just stamps the time for cooldown)."
  def disconnected(%__MODULE__{} = p, endpoint, opts) do
    now = Keyword.fetch!(opts, :now_ms)
    put_ep(p, endpoint, %{ep_state(p, endpoint) | last_attempt: now})
  end

  @doc "Record a failed attempt (grows backoff; may trip the breaker)."
  def failed(%__MODULE__{} = p, endpoint, opts) do
    now = Keyword.fetch!(opts, :now_ms)
    st = ep_state(p, endpoint)
    failures = st.failures + 1

    breaker_until =
      if failures >= p.max_failures, do: now + p.breaker_ms, else: st.breaker_until

    put_ep(p, endpoint, %{st | failures: failures, last_attempt: now, breaker_until: breaker_until})
  end

  # When is the next attempt allowed = last_attempt + max(cooldown, backoff)?
  # last_attempt == nil means "never attempted" → allowed now (return :never so the
  # caller treats it as "in the past" regardless of the monotonic-clock origin,
  # which can be negative — a numeric sentinel is unsafe here).
  defp next_allowed(_p, %{last_attempt: nil}), do: :never

  defp next_allowed(p, st) do
    backoff =
      if st.failures == 0 do
        0
      else
        min(p.base_backoff_ms * round(:math.pow(2, st.failures - 1)), p.max_backoff_ms)
      end

    st.last_attempt + max(p.cooldown_ms, backoff)
  end

  defp ep_state(p, endpoint),
    do: Map.get(p.eps, endpoint, %{last_attempt: nil, failures: 0, breaker_until: nil})

  defp put_ep(p, endpoint, st), do: %{p | eps: Map.put(p.eps, endpoint, st)}
end
