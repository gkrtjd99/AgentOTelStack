# Sample app image. Swap this whole ./app directory to observe your own service —
# just keep emitting OTLP to $OTEL_EXPORTER_OTLP_ENDPOINT (the collector).
FROM node:24-slim@sha256:2c87ef9bd3c6a3bd4b472b4bec2ce9d16354b0c574f736c476489d09f560a203

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src
COPY public ./public

EXPOSE 3000
CMD ["npm", "start"]
