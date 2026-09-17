defmodule PhxMaplibre.Editor.Owner do
  @moduledoc "Application-owned routing contract. Resolve must return the single authoritative document process."
  @callback resolve(String.t(), term()) :: {:ok, pid()} | {:error, term()}
end
