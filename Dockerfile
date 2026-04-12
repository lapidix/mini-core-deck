# Build stage
FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git make gcc musl-dev

WORKDIR /src

# Copy go.work first
COPY go.work /src/go.work

# Copy all three repos
COPY cometbft/ /src/cometbft/
COPY cosmos-sdk/ /src/cosmos-sdk/
COPY chain-minimal/ /src/chain-minimal/

WORKDIR /src/chain-minimal
RUN go build -o /usr/local/bin/minid ./cmd/minid

# Runtime stage
FROM alpine:3.19

RUN apk add --no-cache bash jq curl

COPY --from=builder /usr/local/bin/minid /usr/local/bin/minid

EXPOSE 26656 26657 1317 9090

ENTRYPOINT ["minid"]
