FROM golang:1.26.6-alpine@sha256:af8d6740070b8906d12eae1c3e3ea0957fb63f492051ea05e354c38ef9fe88df AS build
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -o /gateway ./cmd/gateway
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
# Refresh packages in the pinned base so fixed Alpine security updates are
# present in the final runtime image.
RUN apk upgrade --no-cache
COPY --from=build /gateway /gateway
USER 65532:65532
EXPOSE 4318
ENTRYPOINT ["/gateway"]
