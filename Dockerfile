# Stage 1: Build stage
ARG ALPINE_VERSION="3.20"
ARG XMRIG_VERSION="v6.22.0"

FROM alpine:${ALPINE_VERSION} AS builder

# Install build dependencies
RUN echo 'https://dl-cdn.alpinelinux.org/alpine/edge/community' >> /etc/apk/repositories && \
  apk --no-cache add git build-base linux-headers cmake libuv-dev openssl-dev hwloc-dev gcompat

# Clone the specific version of XMRig
RUN git clone https://github.com/xmrig/xmrig.git /xmrig && \
  cd /xmrig && git checkout ${XMRIG_VERSION}

# Modify the source code
RUN sed -i 's/1;/0;/g' /xmrig/src/donate.h

# Build XMRig
WORKDIR /xmrig/build
RUN cmake .. -DWITH_OPENCL=OFF -DWITH_CUDA=OFF && make -j$(nproc)

# Stage 2
FROM alpine:${ALPINE_VERSION}

ARG XMRIG_VERSION
ARG BUILD_DATE
ARG VCS_REF

LABEL org.label-schema.schema-version="1.0" \
  org.label-schema.build-date=$BUILD_DATE \
  org.label-schema.vcs-url="https://github.com/ivuorinen/docker-xmrig" \
  org.label-schema.vcs-ref=$VCS_REF \
  org.label-schema.version=${XMRIG_VERSION}

RUN apk --no-cache add libuv hwloc gcompat && \
  rm -rf /var/cache/apk/* && \
  mkdir -p /etc/xmrig /log

COPY --from=builder /xmrig/build/xmrig /bin/xmrig
COPY config.json /etc/xmrig/config.json

CMD ["/bin/xmrig", "-c", "/etc/xmrig/config.json"]
