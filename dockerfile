ARG ALPINE_IMAGE=alpine:edge

FROM ${ALPINE_IMAGE} AS rtorrent-fetch

WORKDIR /root

RUN apk --no-cache add \
	curl

RUN set -e; \
	ARCH="$(uname -m)"; \
	if [ "$ARCH" = "aarch64" ]; then \
		URL="https://github.com/jesec/rtorrent/releases/latest/download/rtorrent-linux-arm64.deb"; \
	elif [ "$ARCH" = "x86_64" ]; then \
		URL="https://github.com/jesec/rtorrent/releases/latest/download/rtorrent-linux-amd64.deb"; \
	else \
		echo "Unsupported architecture: $ARCH"; \
		exit 1; \
	fi; \
	curl -fL "$URL" -o /root/rtorrent.deb

FROM ${ALPINE_IMAGE} AS rtorrent-sysroot

WORKDIR /root

RUN apk --no-cache add \
	binutils \
	ca-certificates \
	ncurses-terminfo-base

RUN mkdir -p /root/sysroot/etc/ssl/certs
COPY --from=rtorrent-fetch /root/rtorrent.deb ./rtorrent-deb.deb
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
	'mkdir -p /config/flood/session /data' \
	'' \
	'if [ ! -f /config/flood/rtorrent.rc ]; then' \
	'cat > /config/flood/rtorrent.rc << "RC"' \
	'network.scgi.open_local = /config/flood/rtorrent.sock' \
	'execute.nothrow = chmod,770,/config/flood/rtorrent.sock' \
	'session.path.set = /config/flood/session' \
	'directory.default.set = /data' \
	'RC' \
	'fi' \
	'' \
	'rtorrent -n -o import=/config/flood/rtorrent.rc &' \
	'RT_PID="$!"' \
	'sleep 2' \
	'if ! kill -0 "$RT_PID" 2>/dev/null; then' \
	'  echo "rTorrent failed to start" >&2' \
	'  exit 1' \
	'fi' \
	'exec flood --host 0.0.0.0 --allowedpath /data --allowedpath /config/flood' \
	> /usr/local/bin/start-flood-rtorrent.sh

RUN chmod +x /usr/local/bin/start-flood-rtorrent.sh
RUN chown -R 1001:1001 /home/download

USER download

EXPOSE 3000

ENV FLOOD_OPTION_HOST="0.0.0.0"

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/start-flood-rtorrent.sh"]
