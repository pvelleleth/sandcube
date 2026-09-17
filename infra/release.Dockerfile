FROM golang:1.25-alpine AS adapter
WORKDIR /src
COPY services/containerd-runtime/ ./
RUN CGO_ENABLED=0 go build -trimpath -buildvcs=false -o /containerd-runtime .

FROM crystallang/crystal:1.19.1-alpine AS crystal
RUN apk add --no-cache openssl-dev openssl-libs-static zlib-static sqlite-dev sqlite-static
WORKDIR /src
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
COPY migrations/ migrations/
COPY infra/ infra/
COPY scripts/ scripts/
COPY --from=adapter /containerd-runtime /src/bin/containerd-runtime
ARG VERSION=0.1.0
RUN crystal build src/main.cr --release --static -o bin/sandcube-api && \
    crystal build src/launcher.cr --release --static -o bin/sandcube-launcher && \
    crystal run scripts/package.cr -- "$VERSION" bin/sandcube-launcher bin/sandcube-api bin/containerd-runtime scripts/install-deps.sh bin/sandcube

FROM scratch AS release
COPY --from=crystal /src/bin/sandcube /sandcube
