defmodule GsdTracker.Timeline.Rng do
  @moduledoc """
  Counter-based pure randomness for the timeline world.

  There is no RNG state to thread and no `:rand` process seed anywhere in the
  timeline code: the nth decision of a seed is `roll(seed, n)`, a pure hash.
  The same world seed therefore unfolds into byte-identical plans no matter
  when, or from how many processes, the planner runs.
  """

  @two_32 4_294_967_296

  @doc "Uniform draw in `[0, 1)` for a `{seed, counter}` pair."
  @spec roll(term(), term()) :: float()
  def roll(seed, counter), do: :erlang.phash2({seed, counter}, @two_32) / @two_32

  @doc "Uniform draw in `[min, max)`."
  @spec uniform(term(), term(), number(), number()) :: float()
  def uniform(seed, counter, min, max), do: min + roll(seed, counter) * (max - min)

  @doc "Inverse-CDF exponential draw with the given mean (seconds, or any unit)."
  @spec exp(float(), number()) :: float()
  def exp(u, mean), do: -mean * :math.log(1.0 - min(u, 1.0 - 1.0e-12))

  @doc "Standard-normal draw via Box-Muller from two uniform rolls."
  @spec gauss(float(), float()) :: float()
  def gauss(u1, u2) do
    :math.sqrt(-2.0 * :math.log(max(u1, 1.0e-12))) * :math.cos(2.0 * :math.pi() * u2)
  end

  @doc """
  Area-uniform point on a disc: `r = radius * sqrt(u_r)`, uniform bearing.

  Returns `%{lat: _, lng: _}` offset from `center` in the local
  equirectangular metric (1° lat = 111_320 m).
  """
  @spec disc_point(%{lat: float(), lng: float()}, number(), float(), float()) ::
          %{lat: float(), lng: float()}
  def disc_point(center, radius_m, u_r, u_theta) do
    r = radius_m * :math.sqrt(u_r)
    theta = 2.0 * :math.pi() * u_theta
    offset(center, r * :math.cos(theta), r * :math.sin(theta))
  end

  @lat_meters 111_320.0

  @doc "Offset a location by metric north/east meters (equirectangular)."
  @spec offset(%{lat: float(), lng: float()}, number(), number()) ::
          %{lat: float(), lng: float()}
  def offset(%{lat: lat, lng: lng}, north_m, east_m) do
    lng_meters = max(@lat_meters * :math.cos(lat * :math.pi() / 180.0), 1.0e-6)
    %{lat: lat + north_m / @lat_meters, lng: lng + east_m / lng_meters}
  end

  @doc """
  Deterministic RFC-4122-shaped v4 UUID from `{seed, counter}`.

  The 128 bits come from MD5 over the term (not from stacked `phash2` calls:
  those share the 32-bit hash of common subterms, so one subterm collision —
  a ~7 % birthday event across 24k draws — would collide the whole id).
  Version/variant bits are forced, so generated flock/unit ids are stable
  under a pinned world seed.
  """
  @spec uuid(term(), term()) :: Ecto.UUID.t()
  def uuid(seed, counter) do
    <<u0::48, _::4, u1::12, _::2, u2::62>> =
      :crypto.hash(:md5, :erlang.term_to_binary({seed, counter}))

    {:ok, uuid} = Ecto.UUID.load(<<u0::48, 4::4, u1::12, 2::2, u2::62>>)
    uuid
  end
end
