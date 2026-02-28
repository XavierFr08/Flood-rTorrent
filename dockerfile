ARG ALPINE_IMAGE=alpine:edge

FROM ${ALPINE_IMAGE} as rtorrent-build

WORKDIR /root/rtorrent

RUN echo https://dl-cdn.alpinelinux.org/alpine/edge/testing >> /etc/apk/repositories

RUN apk --no-cache add \
	bash \
	bazel \
	build-base \
	coreutils \
	gcompat \
	git \
	linux-headers \
	pythonispython3 \
	python3 \
	rpm

RUN rpm --initdb

RUN git clone https://github.com/jesec/rtorrent .

RUN if [ "$(uname -m)" = "aarch64" ]; then \
	  sed -i 's/architecture = "all"/architecture = "arm64"/' BUILD.bazel; \
	elif [ "$(uname -m)" = "x86_64" ]; then \
	  sed -i 's/architecture = "all"/architecture = "amd64"/' BUILD.bazel; \
	fi

RUN bazel build rtorrent-deb rtorrent-rpm --features=fully_static_link --verbose_failures

RUN mkdir dist
RUN cp -L bazel-bin/rtorrent dist/
RUN cp -L bazel-bin/rtorrent-deb.deb dist/
RUN cp -L bazel-bin/rtorrent-rpm.rpm dist/

FROM ${ALPINE_IMAGE} as rtorrent-sysroot

WORKDIR /root

RUN apk --no-cache add \
	binutils \
	ca-certificates \
	ncurses-terminfo-base

RUN mkdir -p /root/sysroot/etc/ssl/certs
COPY --from=rtorrent-build /root/rtorrent/dist/rtorrent-deb.deb .
RUN ar -xv rtorrent-deb.deb
RUN tar xvf data.tar.* -C /root/sysroot/
RUN cp -L /etc/ssl/certs/ca-certificates.crt /root/sysroot/etc/ssl/certs/ca-certificates.crt
RUN cp -r /etc/terminfo /root/sysroot/etc/terminfo

RUN mkdir -p /root/sysroot/home/download
RUN chown 1001:1001 /root/sysroot/home/download

FROM docker.io/node:22-alpine

ARG PACKAGE_TARBALL=artifacts/flood.tgz

COPY ${PACKAGE_TARBALL} /tmp/flood.tgz
RUN npm i -g /tmp/flood.tgz && \
	node --version && \
	npm ls --global && \
	npm cache clean --force

RUN apk --no-cache add \
	mediainfo \
	tini \
	coreutils

COPY --from=rtorrent-sysroot /root/sysroot/ /

RUN adduser -D -h /home/download -s /sbin/nologin -u 1001 download

RUN printf '%s\n' \
	'#!/bin/sh' \
	'set -e' \
	'' \
	'mkdir -p /home/download/.local/share/rtorrent/session' \
	'' \
	'if [ ! -f /home/download/.rtorrent.rc ]; then' \
	'cat > /home/download/.rtorrent.rc << "RC"' \
	'network.scgi.open_local = /home/download/.rtorrent.sock' \
	'execute.nothrow = chmod,770,/home/download/.rtorrent.sock' \
	'session.path.set = /home/download/.local/share/rtorrent/session' \
	'directory.default.set = /home/download' \
	'RC' \
	'fi' \
	'' \
	'rtorrent -n -o import=/home/download/.rtorrent.rc &' \
	'exec flood' \
	> /usr/local/bin/start-flood-rtorrent.sh

RUN chmod +x /usr/local/bin/start-flood-rtorrent.sh
RUN chown -R 1001:1001 /home/download

USER download

EXPOSE 3000

ENV FLOOD_OPTION_HOST="0.0.0.0"

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/start-flood-rtorrent.sh"]
