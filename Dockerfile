# Multi-stage build: compile a self-contained OTP release, then ship it on a
# thin Debian runtime. Pin both images fully for reproducible builds.
#
# Toolchain matches CI / the line supported by Elixir 1.19: Erlang/OTP 28 on
# Debian bookworm. Bump these together with .github/workflows/ci.yml.
ARG BUILDER_IMAGE="hexpm/elixir:1.19.5-erlang-28.5.0.1-debian-bookworm-20260518-slim"
ARG RUNNER_IMAGE="debian:bookworm-20251229-slim"

FROM ${BUILDER_IMAGE} AS builder

# git: fetch the heroicons GitHub dep. build-essential + curl + ca-certificates:
# compile NIFs and let vix download its precompiled libvips during deps.compile.
RUN apt-get update -y \
  && apt-get install -y build-essential git curl ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Install prod deps first so this layer caches unless mix.exs/mix.lock change.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config (config.exs + prod.exs); runtime.exs is copied later so
# editing it doesn't bust the dep-compile cache.
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Compile first: it generates the colocated-hook manifest that esbuild imports
# (phoenix-colocated/eden), then build, minify, and digest the assets.
RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ---- Runtime image -------------------------------------------------------
FROM ${RUNNER_IMAGE}

# openssl/ncurses/locales: ERTS + TLS. libstdc++6/libgomp1: required by the
# libvips bundled in vix (used for photo thumbnails). ffmpeg: video poster
# frames + duration/dimensions (ffmpeg/ffprobe), shelled out by the media worker.
# libheif-examples: heif-convert (libheif + libde265) — decodes HEIC, which neither
# the bundled libvips (no HEVC) nor the distro ffmpeg can; we transcode HEIC→JPEG
# at upload (#123). curl: the container healthcheck hits /healthz with it (see deploy/).
RUN apt-get update -y \
  && apt-get install -y libstdc++6 libgomp1 openssl libncurses6 locales ca-certificates ffmpeg libheif-examples curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# UTF-8 locale (Elixir expects it).
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Uploads volume (see EDEN_UPLOADS_ROOT in config/runtime.exs); writable by the
# unprivileged runtime user.
RUN mkdir -p /var/lib/eden/uploads && chown -R nobody /var/lib/eden /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/eden ./

USER nobody

EXPOSE 4000

# bin/server sets PHX_SERVER=true and starts the supervised release.
CMD ["/app/bin/server"]
