# keyholder — the registry-credential exchange image.
#
# Go service, distroless/static, no shell. The binary is the only thing in
# the runtime image.

ARG GO_VERSION=1.26

FROM golang:${GO_VERSION} AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOOS=linux
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG SERVICE_NAME=keyholder
RUN go build -trimpath -ldflags="-s -w" -o /out/service ./cmd/${SERVICE_NAME}

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
WORKDIR /app
COPY --from=build /out/service /app/service
USER nonroot:nonroot
EXPOSE 9292
ENTRYPOINT ["/app/service"]
