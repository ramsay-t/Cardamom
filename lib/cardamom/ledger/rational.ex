defmodule Cardamom.Ledger.Rational do
  @moduledoc """
  Exact rational arithmetic for the reward calculation. The Conway ledger spec computes rewards in
  ℚ (unbounded rationals) and applies `floor` only at the end of each sub-calculation
  (Rewards.lagda.md:98-132); floating point diverges from the network, so we need EXACT rationals.
  Elixir has arbitrary-precision integers but no native rationals, so this is a {num, den} pair
  kept normalised (den > 0, gcd-reduced) — a faithful ℚ.

  Ops are exactly those the reward formulas use: +, -, *, ÷ (`div`), min (⊓), floor, from an
  integer, and `div_or_zero` (÷₀ — the spec's zero-denominator-safe division). Comparison too
  (for the `min(1, η)` cap). Never raises on a zero denominator via div_or_zero; a genuine 1/0 in
  `div` is a programming error and does raise.
  """

  # We define div/2, floor/1, min/2, max/2 as rational ops; keep the Kernel versions available
  # qualified (Kernel.div etc., used internally), so exclude the clashing imports.
  import Kernel, except: [div: 2, floor: 1, min: 2, max: 2]

  @enforce_keys [:num, :den]
  defstruct [:num, :den]

  @type t :: %__MODULE__{num: integer(), den: pos_integer()}

  @doc "A rational num/den, normalised (den > 0, reduced). den must be non-zero."
  def new(num, den \\ 1)
  def new(_num, 0), do: raise(ArithmeticError, "rational with zero denominator")

  def new(num, den) when is_integer(num) and is_integer(den) do
    # Keep den positive; reduce by gcd.
    {num, den} = if den < 0, do: {-num, -den}, else: {num, den}
    g = Integer.gcd(abs(num), den)
    g = if g == 0, do: 1, else: g
    # Kernel.div — INTEGER division for the gcd reduction. (Bare `div` here would be OUR rational
    # div/2, causing infinite recursion: new → div → new. The one place inside this module we must
    # reach past the shadow to the Kernel builtin.)
    %__MODULE__{num: Kernel.div(num, g), den: Kernel.div(den, g)}
  end

  @doc "From an integer (fromℕ / fromℤ)."
  def from_int(n) when is_integer(n), do: %__MODULE__{num: n, den: 1}

  @doc "Coerce an integer, {num, den} pair (the wire's tag-30 unit-interval shape), or rational."
  def coerce(%__MODULE__{} = r), do: r
  def coerce(n) when is_integer(n), do: from_int(n)
  def coerce({n, d}) when is_integer(n) and is_integer(d), do: new(n, d)

  def add(a, b), do: bin(a, b, fn %{num: n1, den: d1}, %{num: n2, den: d2} -> new(n1 * d2 + n2 * d1, d1 * d2) end)
  def sub(a, b), do: bin(a, b, fn %{num: n1, den: d1}, %{num: n2, den: d2} -> new(n1 * d2 - n2 * d1, d1 * d2) end)
  def mul(a, b), do: bin(a, b, fn %{num: n1, den: d1}, %{num: n2, den: d2} -> new(n1 * n2, d1 * d2) end)

  @doc "Division a/b. Raises on b == 0 (a real bug); use div_or_zero for the spec's ÷₀."
  def div(a, b), do: bin(a, b, fn %{num: n1, den: d1}, %{num: n2, den: d2} -> new(n1 * d2, d1 * n2) end)

  @doc "The spec's ÷₀: a/b, but 0 when b is 0 (safe on zero stake, etc.)."
  def div_or_zero(a, b) do
    b = coerce(b)
    if b.num == 0, do: from_int(0), else: div(a, b)
  end

  @doc "min (the spec's ⊓)."
  def min(a, b) do
    a = coerce(a)
    b = coerce(b)
    if lte(a, b), do: a, else: b
  end

  @doc "max."
  def max(a, b) do
    a = coerce(a)
    b = coerce(b)
    if lte(a, b), do: b, else: a
  end

  @doc "a <= b."
  def lte(a, b) do
    a = coerce(a)
    b = coerce(b)
    # den > 0 always (normalised), so cross-multiply preserves the inequality.
    a.num * b.den <= b.num * a.den
  end

  @doc "floor to an integer (the coin value). Handles negatives correctly (toward -inf)."
  def floor(%__MODULE__{num: n, den: d}), do: Integer.floor_div(n, d)
  def floor(n) when is_integer(n), do: n

  @doc "posPart(floor x) — the spec's frequent `posPart (floor ...)` for a non-negative coin."
  def floor_pos(r), do: Kernel.max(floor(r), 0)

  @doc "The UnitInterval `clamp`: confine to [0, 1] (used on every relative-stake division)."
  def clamp_unit(r) do
    r = coerce(r)
    r |> max(from_int(0)) |> min(from_int(1))
  end

  @doc """
  EXACT rational from a decimal string — the shelley-genesis params (rho "0.003", tau "0.2",
  a0 "0.3") are decimal-notated rationals; going through a float would substitute the nearest
  binary double for the intended value, and the reward calculation demands the exact ℚ
  (Rewards.lagda.md:98-114 "not suitable for computing rewards"). Accepts an optional exponent
  ("5e-2") since JSON re-emitters sometimes produce one. Raises on anything else.
  """
  def from_decimal!(s) when is_binary(s) do
    {mantissa, exp10} =
      case String.split(s, ["e", "E"]) do
        [m] -> {m, 0}
        [m, e] -> {m, String.to_integer(e)}
      end

    {int_part, frac_part} =
      case String.split(mantissa, ".") do
        [i] -> {i, ""}
        [i, f] -> {i, f}
      end

    digits = String.to_integer(int_part <> frac_part)
    denom_pow = String.length(frac_part) - exp10

    if denom_pow >= 0,
      do: new(digits, Integer.pow(10, denom_pow)),
      else: new(digits * Integer.pow(10, -denom_pow), 1)
  end

  @doc """
  EXACT rational from a JSON-decoded genesis number: integers pass through; floats convert via
  their SHORTEST DECIMAL representation (`Float.to_string/1`), which for a value that was written
  as a short decimal in the genesis file ("0.003") recovers exactly the decimal that was meant —
  NOT the 2^-n expansion of the double.
  """
  def from_json_number(n) when is_integer(n), do: from_int(n)
  def from_json_number(f) when is_float(f), do: from_decimal!(Float.to_string(f))

  # Coerce both args to rationals, apply f.
  defp bin(a, b, f), do: f.(coerce(a), coerce(b))
end
