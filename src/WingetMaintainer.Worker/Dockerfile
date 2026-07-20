# Multi-stage build for the WingetMaintainer Worker (Cronos scheduler + internal API).
#
# The build context MUST be the repository root (the Worker references the Core and Data
# projects and the central build/package props):
#   docker build -f src/WingetMaintainer.Worker/Dockerfile -t winget-maintainer-worker .
# docker/docker-compose.yml sets `context: ..`, so `docker compose build worker` works too.

ARG DOTNET_VERSION=8.0

FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION} AS build
WORKDIR /src

# Restore layer: copy only the files needed to resolve dependencies so this layer stays
# cached until a csproj or a central-package/build file actually changes.
COPY global.json NuGet.config Directory.Build.props Directory.Packages.props ./
COPY src/WingetMaintainer.Worker/WingetMaintainer.Worker.csproj src/WingetMaintainer.Worker/
COPY src/WingetMaintainer.Core/WingetMaintainer.Core.csproj     src/WingetMaintainer.Core/
COPY src/WingetMaintainer.Data/WingetMaintainer.Data.csproj     src/WingetMaintainer.Data/
RUN dotnet restore src/WingetMaintainer.Worker/WingetMaintainer.Worker.csproj

# Build + publish (framework-dependent; the aspnet runtime image provides the runtime).
COPY src/ src/
RUN dotnet publish src/WingetMaintainer.Worker/WingetMaintainer.Worker.csproj \
    -c Release --no-restore -o /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:${DOTNET_VERSION} AS runtime
WORKDIR /app

# komac version baked into the image so the submit pipeline is ready to use out of the box.
# Pin both the version and the tarball checksum; bump together (see SHA256SUMS on the release).
ARG KOMAC_VERSION=2.16.0
ARG KOMAC_SHA256=7d2707fa6210f2789a3702de49fbd150b736dbf426ee0b9bc8e098736f9fd82d

# curl is used by the container HEALTHCHECK to probe /health; ca-certificates + git are needed
# for komac to clone/push winget-pkgs; the komac binary is downloaded and checksum-verified.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates git \
    && curl -fsSL -o /tmp/komac.tar.gz \
    "https://github.com/russellbanks/Komac/releases/download/v${KOMAC_VERSION}/komac-${KOMAC_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
    && echo "${KOMAC_SHA256}  /tmp/komac.tar.gz" | sha256sum -c - \
    && mkdir -p /tmp/komac \
    && tar -xzf /tmp/komac.tar.gz -C /tmp/komac \
    && install -m 0755 /tmp/komac/komac /usr/local/bin/komac \
    && rm -rf /tmp/komac /tmp/komac.tar.gz \
    && rm -rf /var/lib/apt/lists/* \
    && komac --version

COPY --from=build /app/publish ./

# SQLite lives on a writable volume owned by the image's non-root `app` user (UID 1654).
# EF Core runs Database.Migrate() on boot, so /data must be writable.
ENV Worker__DatabasePath=/data/winget-maintainer.db \
    ASPNETCORE_HTTP_PORTS=5099
RUN mkdir -p /data && chown -R app:app /data /app
USER app

EXPOSE 5099
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://localhost:5099/health || exit 1

ENTRYPOINT ["dotnet", "WingetMaintainer.Worker.dll"]
