# Sample app image. Swap this whole ./src/app directory to observe your own service —
# just keep emitting authenticated OTLP to $OTEL_EXPORTER_OTLP_ENDPOINT (the Gateway).
FROM node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 AS deps

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
# Refresh packages in the pinned base so security fixes are not stranded in
# the immutable layer; retain exact runtime ABI pins for Node's native deps.
RUN apk upgrade --no-cache \
 && apk add --no-cache libstdc++=14.2.0-r6 libgcc=14.2.0-r6
RUN addgroup -S app && adduser -S -G app app
COPY --from=deps /usr/local/bin/node /usr/local/bin/node
COPY --from=deps /app/node_modules /app/node_modules
WORKDIR /app

COPY src ./src
COPY public ./public
RUN chown -R app:app /app
USER app

EXPOSE 3000
HEALTHCHECK --interval=5s --timeout=3s --retries=20 CMD ["node", "-e", "require('http').get('http://127.0.0.1:3000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"]
CMD ["node", "--require", "./src/otel.js", "src/index.js"]
