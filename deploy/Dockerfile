# Deployment image for both demo apps (one BEAM, endpoints on 4001 + 4002).
FROM elixir:1.20-otp-27

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates nodejs npm postgresql-client \
      gdal-bin osmium-tool && \
    rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod LANG=C.UTF-8

WORKDIR /app
COPY . .

RUN mix local.hex --force && mix local.rebar --force && \
    mix deps.get --only prod && \
    npm --prefix apps/demo_berlin_districts/assets install --no-audit --no-fund && \
    npm --prefix apps/demo_gsd_tracker/assets install --no-audit --no-fund && \
    mix compile && \
    (cd apps/demo_berlin_districts && mix assets.deploy) && \
    (cd apps/demo_gsd_tracker && mix assets.deploy)

EXPOSE 4001 4002

ENTRYPOINT ["/app/deploy/entrypoint.sh"]
