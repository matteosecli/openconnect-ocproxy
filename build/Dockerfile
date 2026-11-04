FROM alpine:3.24.3

ARG USER=docker

# Without the leading "v"; Alpine stable package, then Alpine edge package, then source build
ARG OPENCONNECT_VERSION=9.21
ARG OPENCONNECT_TARBALL_URL=https://www.infradead.org/openconnect/download/openconnect-${OPENCONNECT_VERSION}.tar.gz
ARG OPENCONNECT_GIT_URL=https://gitlab.com/openconnect/openconnect.git
ARG ALPINE_EDGE_COMMUNITY=https://dl-cdn.alpinelinux.org/alpine/edge/community
# With the leading "v"; a musl release binary is preferred, source build is the fallback
ARG OCPROXY_VERSION=v2.0.0-rc.2
ARG OCPROXY_REPO=https://github.com/matteosecli/ocproxy

RUN addgroup -S "$USER" && \
    adduser \
    --disabled-password \
    --gecos "" \
    --ingroup "$USER" \
    --no-create-home \
    --uid "12345" \
    "$USER"

RUN apk add --no-cache ca-certificates tzdata

# openconnect: Alpine package (stable, then edge) if the requested version exists, otherwise build from source and drop the build deps in the same layer
RUN set -eux; \
    if apk add --no-cache "openconnect~=${OPENCONNECT_VERSION}"; then \
        echo "Installed openconnect ${OPENCONNECT_VERSION} from Alpine stable packages"; \
    elif apk add --no-cache -X "${ALPINE_EDGE_COMMUNITY}" "openconnect~=${OPENCONNECT_VERSION}"; then \
        echo "Installed openconnect ${OPENCONNECT_VERSION} from Alpine edge packages"; \
    else \
        echo "openconnect ${OPENCONNECT_VERSION} not in Alpine packages, building from source"; \
        apk add --no-cache vpnc iproute2 libxml2 lz4-libs krb5-libs pcsc-lite-libs libproxy oath-toolkit-libpskc stoken zlib openssl; \
        apk add --no-cache --virtual .oc-build-deps \
            curl build-base autoconf automake libtool gettext-dev pkgconf linux-headers git \
            openssl-dev libxml2-dev lz4-dev krb5-dev pcsc-lite-dev libproxy-dev oath-toolkit-dev stoken-dev zlib-dev; \
        mkdir /tmp/openconnect-src; \
        if curl -fsSL "${OPENCONNECT_TARBALL_URL}" | tar xz -C /tmp/openconnect-src --strip-components=1; then \
            cd /tmp/openconnect-src; \
        else \
            rm -rf /tmp/openconnect-src; \
            git clone --depth 1 --branch "v${OPENCONNECT_VERSION}" "${OPENCONNECT_GIT_URL}" /tmp/openconnect-src; \
            cd /tmp/openconnect-src; \
        fi; \
        [ -x configure ] || sh autogen.sh; \
        ./configure --prefix=/usr --with-vpnc-script=/etc/vpnc/vpnc-script --without-gnutls --with-openssl; \
        make -j"$(nproc)"; \
        make install-strip; \
        cd /; \
        rm -rf /tmp/openconnect-src; \
        apk del --no-cache .oc-build-deps; \
    fi; \
    openconnect --version

# ocproxy: musl release binary if available/compatible, otherwise build from source and drop the build deps in the same layer
RUN set -eux; \
    apk add --no-cache --virtual .ocproxy-fetch-deps curl; \
    install_binary() { \
        case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) return 1 ;; esac; \
        name="ocproxy-${OCPROXY_VERSION}-linux-musl-${arch}.tar.gz"; \
        mkdir /tmp/ocproxy-bin && cd /tmp/ocproxy-bin; \
        curl -fsSLO "${OCPROXY_REPO}/releases/download/${OCPROXY_VERSION}/${name}"; \
        curl -fsSLO "${OCPROXY_REPO}/releases/download/${OCPROXY_VERSION}/SHA256SUMS"; \
        grep " ${name}\$" SHA256SUMS | sha256sum -c -; \
        tar xzf "${name}" --strip-components=1; \
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
        curl -fsSL "${OCPROXY_REPO}/releases/download/${OCPROXY_VERSION}/ocproxy-${OCPROXY_VERSION}-source.tar.gz" \
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
    rm -rf /tmp/ocproxy-bin /tmp/ocproxy-src; \
    apk del --no-cache .ocproxy-fetch-deps

WORKDIR /openconnect-proxy
COPY ./entrypoint.sh .

USER $USER

EXPOSE 9876

ENTRYPOINT ["/openconnect-proxy/entrypoint.sh"]
