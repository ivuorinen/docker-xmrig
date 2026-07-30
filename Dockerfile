# Stage 1: Build stage
# renovate: datasource=github-tags depName=xmrig/xmrig
ARG XMRIG_VERSION="v6.22.2"

FROM alpine:3.24 AS builder

# The global ARG above is outside every build stage; it MUST be redeclared here or
# it expands to the empty string and the checkout silently builds master HEAD.
ARG XMRIG_VERSION

# Install build dependencies. Everything below is in Alpine 3.24 main/community —
# do not add the edge repository, it makes builds unpinned and splits the ABI
# between this stage and the runtime stage.
RUN apk --no-cache add git build-base linux-headers cmake libuv-dev openssl-dev hwloc-dev

# Clone the specific version of XMRig. --branch fails the build on an unknown tag.
RUN test -n "${XMRIG_VERSION}" && \
  git clone --depth 1 --branch "${XMRIG_VERSION}" https://github.com/xmrig/xmrig.git /xmrig

# Disable the built-in donation. The grep guards turn a silent no-op (upstream
# reformatting donate.h) into a build failure instead of a 1% donate level.
RUN sed -i -E 's/^(constexpr const int kDefaultDonateLevel) = [0-9]+;/\1 = 0;/' /xmrig/src/donate.h && \
  sed -i -E 's/^(constexpr const int kMinimumDonateLevel) = [0-9]+;/\1 = 0;/' /xmrig/src/donate.h && \
  grep -q 'kDefaultDonateLevel = 0;' /xmrig/src/donate.h && \
  grep -q 'kMinimumDonateLevel = 0;' /xmrig/src/donate.h

# Build XMRig
WORKDIR /xmrig/build
RUN cmake .. -DWITH_OPENCL=OFF -DWITH_CUDA=OFF && make -j"$(nproc)"

# Stage 2
FROM alpine:3.24

ARG XMRIG_VERSION

# docker/metadata-action supplies the other org.opencontainers.image.* labels
# (created, revision, source) at build time; only the upstream miner version is
# knowledge this Dockerfile alone has.
LABEL org.opencontainers.image.version="${XMRIG_VERSION}" \
  org.opencontainers.image.licenses="GPL-3.0-or-later"

RUN apk --no-cache add libuv hwloc && \
  adduser -S -u 10001 -H -h /log xmrig && \
  mkdir -p /etc/xmrig /log && \
  chown 10001 /log

COPY --from=builder /xmrig/build/xmrig /bin/xmrig
COPY config.json /etc/xmrig/config.json

# GPL-3.0 sec. 5/6: the binary is a modified work, so it travels with the upstream
# licence and with the file this build modifies. See NOTICE at the repository root.
COPY --from=builder /xmrig/LICENSE /usr/share/licenses/xmrig/LICENSE
COPY --from=builder /xmrig/src/donate.h /usr/share/licenses/xmrig/donate.h
COPY NOTICE /usr/share/licenses/xmrig/NOTICE

USER 10001

# Liveness only: catches a wedged or unresponsive process. It does NOT detect a
# disconnected pool — the API answers happily at zero hashrate. For that, alert on
# .connection.pool == "" from /2/summary; it is deliberately not wired to the
# healthcheck, because restarting on a pool outage turns their outage into a
# crashloop. Requires the "http" block in config.json to stay enabled.
HEALTHCHECK --interval=60s --timeout=5s --start-period=120s \
  CMD wget -qO- http://127.0.0.1:8080/2/summary >/dev/null 2>&1 || exit 1

CMD ["/bin/xmrig", "-c", "/etc/xmrig/config.json"]
