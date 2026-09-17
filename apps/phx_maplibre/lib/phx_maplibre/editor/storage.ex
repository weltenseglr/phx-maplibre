defmodule PhxMaplibre.Editor.Storage do
  @moduledoc "Persistence contract. Commit must atomically compare the document version before writing the complete opaque state."
  @callback load(String.t(), term()) :: {:ok, map() | nil} | {:error, term()}
  @callback commit(String.t(), {String.t(), non_neg_integer()}, map(), term()) ::
              :ok | {:error, term()}
end
