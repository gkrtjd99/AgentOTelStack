# Sample app image. Swap this whole ./app directory to observe your own service —
# just keep emitting OTLP to $OTEL_EXPORTER_OTLP_ENDPOINT (the collector).
FROM node:24-slim

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY src ./src
COPY public ./public

EXPOSE 3000
CMD ["npm", "start"]
