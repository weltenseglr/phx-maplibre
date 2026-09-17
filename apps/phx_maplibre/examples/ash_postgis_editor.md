# Persisting editor documents alongside Ash/PostGIS geometry

This application example uses the Ecto repository shared by an AshPostgres
application. It does not add Ash, Ecto, or PostGIS dependencies to phx-maplibre.
Its adapter persists the complete editor document in `bytea` and maintains a
queryable PostGIS row for each feature in the same transaction. Application Ash
resources may map these tables for reads; editor mutations go through the
document owner and this adapter rather than independently updating geometry.

Create the following tables in an application migration, with PostGIS installed:

```sql
CREATE TABLE editor_documents (
  document_id text PRIMARY KEY,
  generation text NOT NULL,
  revision bigint NOT NULL,
  editor_state bytea NOT NULL
);
CREATE TABLE editor_features (
  document_id text NOT NULL REFERENCES editor_documents(document_id) ON DELETE CASCADE,
  feature_id text NOT NULL,
  properties jsonb NOT NULL,
  geometry geometry(Geometry, 4326) NOT NULL,
  PRIMARY KEY (document_id, feature_id)
);
CREATE INDEX editor_features_geometry_idx ON editor_features USING gist (geometry);
```

The durable document includes generation, revision, ordinary GeoJSON features,
coordinate nodes and tombstones, per-feature metadata and acknowledgements,
settings, and operation receipts. The following adapter treats that state as
opaque for persistence; only the geometry projection reads feature entries.

```elixir
defmodule MyApp.EditorStorage do
  @behaviour PhxMaplibre.Editor.Storage
  alias Ecto.Adapters.SQL

  @impl true
  def load(document_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    case SQL.query(repo,
           "SELECT editor_state FROM editor_documents WHERE document_id = $1",
           [document_id]) do
      {:ok, %{rows: []}} -> {:ok, nil}
      {:ok, %{rows: [[binary]]}} ->
        {:ok, :erlang.binary_to_term(binary, [:safe])}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def commit(document_id, {generation, revision}, next_state, opts) do
    repo = Keyword.fetch!(opts, :repo)
    binary = :erlang.term_to_binary(next_state, [:compressed])

    repo.transaction(fn ->
      params = [document_id, next_state.generation, next_state.revision,
                binary, generation, revision]

      # Only an initial revision may insert a previously absent document.
      statement = if revision == 0 do
        """
        INSERT INTO editor_documents
          (document_id, generation, revision, editor_state)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (document_id) DO UPDATE
          SET generation = EXCLUDED.generation,
              revision = EXCLUDED.revision,
              editor_state = EXCLUDED.editor_state
          WHERE editor_documents.generation = $5
            AND editor_documents.revision = $6
        """
      else
        """
        UPDATE editor_documents
          SET generation = $2, revision = $3, editor_state = $4
          WHERE document_id = $1 AND generation = $5 AND revision = $6
        """
      end

      case SQL.query(repo, statement, params) do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, _} -> repo.rollback(:stale_document)
        {:error, reason} -> repo.rollback(reason)
      end

      # A complete projection is deliberately simple. Large documents can use
      # changed-feature upserts, while retaining this transaction boundary.
      SQL.query!(repo,
        "DELETE FROM editor_features WHERE document_id = $1", [document_id])

      Enum.each(next_state.features, fn {id, entry} ->
        feature = entry.feature
        SQL.query!(repo, """
          INSERT INTO editor_features
            (document_id, feature_id, properties, geometry)
          VALUES ($1, $2, $3::jsonb,
                  ST_SetSRID(ST_GeomFromGeoJSON($4), 4326))
          """, [document_id, id, Jason.encode!(feature["properties"]),
                Jason.encode!(feature["geometry"])])
      end)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end
end
```

Enable it explicitly:

```elixir
{PhxMaplibre.Editor.Runtime,
 name: MyApp.EditorRuntime,
 pubsub: MyApp.PubSub,
 storage: {MyApp.EditorStorage, repo: MyApp.Repo}}
```

In an AshPostgres resource, map the document/feature identifiers, `properties`,
and the geometry column using the application's existing AshPostGIS type and
SRID configuration. Do not expose a geometry update action that bypasses the
editor state: it would invalidate vertex identities and collaboration history.
An application action can instead resolve the document owner and submit an
editor operation. The library requires no knowledge of those Ash resources.

For JSONB document storage, encode the entire state with Jason and return the
decoded map from `load/2`; the runtime normalizes its known document keys.
Preserve all metadata, tombstones, and receipts, not just the feature collection.
The binary example avoids that conversion and reads only application-owned
records with `binary_to_term(..., [:safe])`.

Shared persistence does not provide a document owner. For multiple application
nodes, additionally supply `{MyApp.EditorOwner, opts}` as `owner:`. Its
`resolve(document_id, opts)` must return `{:ok, pid}` for exactly one live,
authoritative document process. That owner must be started with the same PubSub
and storage configuration. Application-specific routing or election belongs in
this adapter; the compare-and-swap above prevents a stale process from committing
but does not replace ownership routing.

Verify your adapter against a real database: failed or stale commits must leave
both tables unchanged, concurrent owners must not both commit the same version,
and restarting the owner must restore geometry, IDs, acknowledgements, and
receipts. This example has not been exercised against an Ash/PostGIS database.
