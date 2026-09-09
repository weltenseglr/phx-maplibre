FROM mcr.microsoft.com/devcontainers/cpp:1-ubuntu-24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        inotify-tools \
        libgdal-dev \
        libpq-dev \
        build-essential \
        gnupg \
        lsb-release \
        software-properties-common \
        wget \
        unzip \
        zip \
        locales \
        osmium-tool \
        gdal-bin \
        && rm -rf /var/lib/apt/lists/*

# The full land-cover archive was made by PostgreSQL 18. Install its client
# explicitly; Ubuntu 24.04's stock client is PostgreSQL 16 and cannot read it.
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
      gpg --dearmor -o /usr/share/keyrings/postgresql.gpg && \
    . /etc/os-release && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends postgresql-client-18 && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/lib/postgresql/18/bin:${PATH}"

RUN apt-get update && \
    apt-get install -y --no-install-recommends erlang erlang-dev elixir && \
    rm -rf /var/lib/apt/lists/*

RUN apt-get update && \
    apt-get install -y --no-install-recommends nodejs npm && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
