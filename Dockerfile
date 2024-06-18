ARG UBUNTU_VERSION="noble-20240605"
ARG XMRIG_VERSION="v6.21.3"

FROM ubuntu:${UBUNTU_VERSION} as prepare

ENV TZ=Europe/Helsinki
ENV PATH=/xmrig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV XMRIG_URL=https://github.com/xmrig/xmrig.git

RUN DEBIAN_FRONTEND=noninteractive \
    apt-get update && \
    apt-get -y install git build-essential cmake libuv1-dev libssl-dev libhwloc-dev

RUN git clone ${XMRIG_URL} /xmrig && \
    cd /xmrig && git checkout ${XMRIG_VERSION}

WORKDIR /xmrig/build
RUN sed -i 's/1;/0;/g' ../src/donate.h
RUN cmake .. -DWITH_OPENCL=OFF -DWITH_CUDA=OFF && make -j$(nproc)

COPY config.json /xmrig/build/conf/

###
FROM ubuntu:${UBUNTU_VERSION}

ARG BUILD_DATE
ARG VCS_REF
ARG XMRIG_VERSION

LABEL org.label-schema.build-date=$BUILD_DATE \
      org.label-schema.vcs-url="https://github.com/ivuorinen/docker-xmrig" \
      org.label-schema.vcs-ref=$VCS_REF \
      org.label-schema.schema-version=$XMRIG_VERSION

WORKDIR /xmrig

COPY --from=prepare /xmrig/build/conf/config.json /xmrig/config.json
COPY --from=prepare /xmrig/build/xmrig /xmrig/xmrig
RUN DEBIAN_FRONTEND=noninteractive \
    apt-get update \
    && apt-get -y --no-install-recommends install libuv1 libhwloc15 \
    && apt-get purge -y --auto-remove \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir /xmrig/log 

CMD ["/xmrig/xmrig", "-c", "/xmrig/config.json"]
