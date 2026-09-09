# Reproducible OSM land-cover build and restore tooling for the demo Compose
# stack. PostGIS lives in the database service; this image only needs
# the PostgreSQL client plus the OSM/GDAL command-line tools.
FROM postgres:18-bookworm

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gdal-bin \
      osmium-tool && \
    rm -rf /var/lib/apt/lists/*
