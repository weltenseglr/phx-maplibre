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
        autoconf \
        m4 \
        libssl-dev \
        libncurses-dev \
        libssh-dev \
        unixodbc-dev \
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

ENV ASDF_DIR=/home/vscode/.asdf \
    ASDF_DATA_DIR=/home/vscode/.asdf \
    MIX_HOME=/home/vscode/.mix \
    HEX_HOME=/home/vscode/.hex \
    KERL_CONFIGURE_OPTIONS="--without-wx"
ENV PATH="/home/vscode/.asdf/shims:/home/vscode/.asdf/bin:/usr/lib/postgresql/18/bin:${PATH}"

# Keep the shell-based asdf version used by the former runtime features.
# Runtime versions themselves are defined only in .tool-versions.
RUN mkdir -p /home/vscode/.mix /home/vscode/.hex && \
    git clone --depth 1 --branch v0.12.0 https://github.com/asdf-vm/asdf.git /home/vscode/.asdf && \
    chown -R vscode:vscode /home/vscode/.asdf /home/vscode/.mix /home/vscode/.hex

WORKDIR /workspace

COPY .tool-versions /workspace/.tool-versions
COPY .devcontainer/install-tools.sh /usr/local/bin/install-project-tools
RUN bash /usr/local/bin/install-project-tools
RUN chown -R vscode:vscode /home/vscode/.asdf /home/vscode/.mix /home/vscode/.hex

# Raw compose/container exec must use UTF-8 too, not just editor sessions.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
