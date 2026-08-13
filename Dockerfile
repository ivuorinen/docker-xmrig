# Stage 1: Build stage
# renovate: datasource=github-tags depName=xmrig/xmrig
ARG XMRIG_VERSION="v6.22.2"

# The commit XMRIG_VERSION resolved to when it was pinned. A git tag is a MUTABLE
# pointer — upstream can move it, and every later build of this unchanged
# Dockerfile would then compile different source under the same version label,
# which neither --branch nor the version smoke test can detect. This is the pin
# that actually holds.
#
# Renovate bumps XMRIG_VERSION from the annotation above; it does NOT touch this
# line — no annotation and no customManager covers it. So every xmrig bump PR is
# red by construction: the rev-parse check below fails, prints the tag's real
# commit, and a maintainer pastes it here on the same branch. The SHA is already
# in the failed build log ("got <sha>") — no lookup needed. To check by hand:
#   git ls-remote https://github.com/xmrig/xmrig.git 'refs/tags/<tag>^{}' 'refs/tags/<tag>'
ARG XMRIG_COMMIT="f9e990d0f0167c92d09334213ac6950033bbbba1"

# Digest-pinned: `alpine:3.24` alone is a floating tag, republished on every
# 3.24.x patch, so the same commit would otherwise build different images.
# Renovate bumps the digest. Declared ONCE and shared by both stages on purpose:
# xmrig is compiled here and the bare binary is copied into the runtime stage, so
# if the two stages ever resolved to different bases the binary would link
# against a different musl/libuv/hwloc/OpenSSL than the one that runs it.
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS base

FROM base AS builder

# The global ARGs above are outside every build stage; they MUST be redeclared
# here or they expand to the empty string and the checkout silently builds
# master HEAD.
ARG XMRIG_VERSION
ARG XMRIG_COMMIT

# Install build dependencies. Everything below is in Alpine 3.24 main/community —
# do not add the edge repository, it makes builds unpinned and splits the ABI
# between this stage and the runtime stage.
RUN apk --no-cache add git build-base linux-headers cmake libuv-dev openssl-dev hwloc-dev

# Clone the specific version of XMRig. --branch fails the build on an unknown tag;
# the rev-parse check fails it on a tag that has been MOVED since XMRIG_COMMIT was
# recorded, which --branch alone cannot see.
RUN test -n "${XMRIG_VERSION}" && test -n "${XMRIG_COMMIT}" && \
  git clone --depth 1 --branch "${XMRIG_VERSION}" https://github.com/xmrig/xmrig.git /xmrig && \
  actual="$(git -C /xmrig rev-parse HEAD)" && \
  if [ "${actual}" != "${XMRIG_COMMIT}" ]; then \
    echo "upstream tag ${XMRIG_VERSION} moved: expected ${XMRIG_COMMIT}, got ${actual}"; \
    exit 1; \
  fi

# Disable the built-in donation. The grep guards turn a silent no-op (upstream
# reformatting donate.h) into a build failure instead of a 1% donate level.
RUN sed -i -E 's/^(constexpr const int kDefaultDonateLevel) = [0-9]+;/\1 = 0;/' /xmrig/src/donate.h && \
  sed -i -E 's/^(constexpr const int kMinimumDonateLevel) = [0-9]+;/\1 = 0;/' /xmrig/src/donate.h && \
  grep -q 'kDefaultDonateLevel = 0;' /xmrig/src/donate.h && \
  grep -q 'kMinimumDonateLevel = 0;' /xmrig/src/donate.h

# Build XMRig. Every option this image's contract depends on is pinned rather
# than inherited from upstream: WITH_HTTP backs the HEALTHCHECK below and the
# Kubernetes probes, WITH_TLS is why libssl3 is installed in the runtime stage,
# and Release is what makes this -Ofast instead of -O0. All three are upstream
# defaults today — pinned so an automated XMRIG_VERSION bump cannot flip one
# silently, which no check in CI would catch.
WORKDIR /xmrig/build
RUN cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DWITH_HTTP=ON \
  -DWITH_TLS=ON \
  -DWITH_OPENCL=OFF \
  -DWITH_CUDA=OFF && \
  make -j"$(nproc)"

# Stage 2 — same `base` as the builder, see the FROM comment at the top.
FROM base

ARG XMRIG_VERSION

# Build-time defaults only. Labels passed to buildx OVERRIDE these, and the
# release workflow passes docker/metadata-action's set — which by default would
# replace .licenses with the repo's MIT licence and .version with the git tag.
# build.yaml pins both back to the values below; keep the two in sync.
# .source is set here too, not just by metadata-action, so that a locally built
# image also carries the pointer NOTICE relies on for GPL corresponding source.
LABEL org.opencontainers.image.version="${XMRIG_VERSION}" \
  org.opencontainers.image.licenses="GPL-3.0-or-later" \
  org.opencontainers.image.source="https://github.com/ivuorinen/docker-xmrig"

# libssl3 is not optional: xmrig is built WITH_TLS, so /bin/xmrig links
# libssl.so.3 and libcrypto.so.3. They happen to be present via apk-tools, but
# that is apk's dependency, not ours — declare it so a base-image change cannot
# silently remove them.
RUN apk --no-cache add libuv hwloc libssl3 && \
  adduser -S -u 10001 -H -h /log xmrig && \
  mkdir -p /etc/xmrig /log && \
  chown 10001 /log

COPY --from=builder /xmrig/build/xmrig /bin/xmrig
COPY config.json /etc/xmrig/config.json

# GPL-3.0 sec. 5/6: the binary is a modified work, so it travels with the upstream
# licence and with the file this build modifies. See NOTICE at the repository root.
# The two licences are named apart on purpose — NOTICE says "the packaging is MIT,
# see LICENSE", and a bare `LICENSE` next to it holding the GPL text said the
# opposite to anyone who followed that pointer inside the image.
COPY --from=builder /xmrig/LICENSE /usr/share/licenses/xmrig/LICENSE.xmrig-GPL-3.0
COPY --from=builder /xmrig/src/donate.h /usr/share/licenses/xmrig/donate.h
COPY NOTICE /usr/share/licenses/xmrig/NOTICE
COPY LICENSE /usr/share/licenses/xmrig/LICENSE.packaging-MIT

USER 10001

# Liveness only: catches a wedged or unresponsive process. It does NOT detect a
# disconnected pool — the API answers happily at zero hashrate. For that, alert on
# .connection.pool == "" from /2/summary; it is deliberately not wired to the
# healthcheck, because restarting on a pool outage turns their outage into a
# crashloop. Requires the "http" block in config.json to stay enabled.
#
# Exec form, not shell form. hadolint 2.15 raises DL3025 on the shell form, and
# the lint job runs at failure-threshold=info and gates every publish job — so a
# shell-form healthcheck here pins the repository to hadolint 2.14 forever. The
# `|| exit 1` the shell form needed is redundant anyway: wget already exits
# non-zero on a failed request, which is what Docker reads. /dev/null is a device
# node, so this still works under the --read-only every consumer applies.
# build.yaml runs this same argv by reading it back out of the built image.
HEALTHCHECK --interval=60s --timeout=5s --start-period=120s \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/2/summary"]

CMD ["/bin/xmrig", "-c", "/etc/xmrig/config.json"]
