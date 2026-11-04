FROM alpine:3.24.3

ARG USER=vpn
ARG UID=12345

# openconnect, without the leading "v": Alpine stable package, then Alpine edge package,
# then a source build (pinned release tarball first, GitLab tag as last resort).
ARG OPENCONNECT_VERSION=9.21
# SHA-256 of the signed upstream release tarball (verified against the maintainer's detached signature)
ARG OPENCONNECT_SHA256=5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58
ARG OPENCONNECT_TARBALL_URL=https://www.infradead.org/openconnect/download/openconnect-${OPENCONNECT_VERSION}.tar.gz
ARG OPENCONNECT_GIT_URL=https://gitlab.com/openconnect/openconnect.git
ARG ALPINE_EDGE_COMMUNITY=https://dl-cdn.alpinelinux.org/alpine/edge/community

# ocproxy, with the leading "v": musl release binary, else source build.
# Pinned checksums are used when set for the target architecture, otherwise the release's SHA256SUMS.
ARG OCPROXY_VERSION=v2.0.0-rc.2
ARG OCPROXY_REPO=https://github.com/matteosecli/ocproxy
ARG OCPROXY_SHA256_AMD64=37a6233a175a403575c01c8fd17dbf5c2a5e4707193fcc370e0291dce775cc66
ARG OCPROXY_SHA256_ARM64=d079641bd1ffb1aea0da4806238d87a00e22d2c05236aeb8053e628ca746f62b

# Only bash is added on top of the base image (busybox provides timeout/flock/setsid/date/mktemp/mkfifo).
# curl is needed only for the optional VPN_HEALTH_URL startup probe: build with --build-arg INSTALL_CURL=1.
ARG INSTALL_CURL=0
RUN apk add --no-cache bash && \
    if [ "$INSTALL_CURL" = 1 ]; then apk add --no-cache curl; fi && \
    addgroup -S -g "$UID" "$USER" && \
    adduser -S -D -H -u "$UID" -G "$USER" "$USER" && \
    mkdir -p /run/vpn /usr/local/libexec && \
    chown "$UID:$UID" /run/vpn

# openconnect: build deps are removed in the same layer
RUN set -eux; \
    if apk add --no-cache "openconnect~=${OPENCONNECT_VERSION}"; then \
        echo "Installed openconnect ${OPENCONNECT_VERSION} from Alpine stable packages"; \
    elif apk add --no-cache -X "${ALPINE_EDGE_COMMUNITY}" "openconnect~=${OPENCONNECT_VERSION}"; then \
        echo "Installed openconnect ${OPENCONNECT_VERSION} from Alpine edge packages"; \
    else \
        echo "openconnect ${OPENCONNECT_VERSION} not in Alpine packages, building from source"; \
        apk add --no-cache libssl3 libcrypto3 libxml2 zlib lz4-libs; \
        apk add --no-cache --virtual .oc-build-deps \
            build-base pkgconf linux-headers openssl-dev libxml2-dev zlib-dev lz4-dev; \
        mkdir /tmp/openconnect-src; \
        if wget -q -O /tmp/openconnect.tar.gz "${OPENCONNECT_TARBALL_URL}" \
            && echo "${OPENCONNECT_SHA256}  /tmp/openconnect.tar.gz" | sha256sum -c -; then \
            tar -xzf /tmp/openconnect.tar.gz -C /tmp/openconnect-src --strip-components=1; \
        else \
            echo "Pinned release tarball unavailable, falling back to the unsigned git tag"; \
            apk add --no-cache --virtual .oc-git-deps git autoconf automake libtool gettext-dev; \
            rm -rf /tmp/openconnect-src; \
            git clone --depth 1 --branch "v${OPENCONNECT_VERSION}" "${OPENCONNECT_GIT_URL}" /tmp/openconnect-src; \
            (cd /tmp/openconnect-src && sh autogen.sh); \
        fi; \
        cd /tmp/openconnect-src; \
        ./configure --prefix=/usr/local --disable-nls --with-openssl --without-gnutls --without-libproxy --without-libpskc \
            --with-vpnc-script=/usr/local/libexec/vpnc-script-unused; \
        make -j"$(nproc)"; \
        make install-strip; \
        printf '#!/bin/sh\necho "This image requires --script-tun with its proxy helper." >&2\nexit 1\n' \
            > /usr/local/libexec/vpnc-script-unused; \
        chmod 755 /usr/local/libexec/vpnc-script-unused; \
        cd /; \
        rm -rf /tmp/openconnect-src /tmp/openconnect.tar.gz; \
        apk del --no-cache .oc-build-deps; \
        apk del --no-cache .oc-git-deps 2>/dev/null || true; \
    fi; \
    mkdir -p /usr/local/sbin; \
    [ -x /usr/local/sbin/openconnect ] || ln -s "$(command -v openconnect)" /usr/local/sbin/openconnect; \
    /usr/local/sbin/openconnect --version

# ocproxy: build deps are removed in the same layer
RUN set -eux; \
    install_binary() { \
        case "$(uname -m)" in \
            x86_64) arch=amd64; pinned="${OCPROXY_SHA256_AMD64}" ;; \
            aarch64) arch=arm64; pinned="${OCPROXY_SHA256_ARM64}" ;; \
            *) return 1 ;; \
        esac; \
        name="ocproxy-${OCPROXY_VERSION}-linux-musl-${arch}"; \
        mkdir /tmp/ocproxy-bin && cd /tmp/ocproxy-bin; \
        wget -q "${OCPROXY_REPO}/releases/download/${OCPROXY_VERSION}/${name}.tar.gz"; \
        if [ -n "$pinned" ]; then \
            printf '%s  %s\n' "$pinned" "${name}.tar.gz" | sha256sum -c -; \
        else \
            wget -q "${OCPROXY_REPO}/releases/download/${OCPROXY_VERSION}/SHA256SUMS"; \
            grep " ${name}.tar.gz\$" SHA256SUMS | sha256sum -c -; \
        fi; \
        tar xzf "${name}.tar.gz" --strip-components=1; \
        install -m 0755 ocproxy /usr/local/bin/ocproxy; \
        ocproxy -h >/dev/null; \
    }; \
    if (install_binary); then \
        echo "Installed ocproxy ${OCPROXY_VERSION} release binary"; \
    else \
        echo "No usable ocproxy ${OCPROXY_VERSION} binary, building from source"; \
        rm -f /usr/local/bin/ocproxy; \
        apk add --no-cache libevent; \
        apk add --no-cache --virtual .ocproxy-build-deps build-base autoconf automake libtool linux-headers libevent-dev; \
        mkdir /tmp/ocproxy-src; \
        wget -q -O - "${OCPROXY_REPO}/releases/download/${OCPROXY_VERSION}/ocproxy-${OCPROXY_VERSION}-source.tar.gz" \
            | tar xz -C /tmp/ocproxy-src --strip-components=1; \
        cd /tmp/ocproxy-src; \
        [ -x configure ] || sh autogen.sh; \
        ./configure --prefix=/usr/local; \
        make -j"$(nproc)"; \
        make install-strip; \
        apk del --no-cache .ocproxy-build-deps; \
        ocproxy -h >/dev/null; \
    fi; \
    cd /; \
    rm -rf /tmp/ocproxy-bin /tmp/ocproxy-src

COPY --chmod=755 libexec/ /usr/local/libexec/
COPY --chmod=755 bin/ /usr/local/bin/

USER $UID:$UID

ENV VPN_RUNTIME=/run/vpn OPENCONNECT_BIN=/usr/local/sbin/openconnect

EXPOSE 9876

ENTRYPOINT ["/usr/local/bin/vpn-service"]
