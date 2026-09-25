# Build context is the repo root: the image serves web/ at / and docs/ at /docs, like deploy-pages.yml.
FROM oven/bun:1-alpine AS web
WORKDIR /app/web
COPY web/package.json web/bun.lock ./
RUN bun install --frozen-lockfile
COPY web ./
# Same non-fatal refresh as deploy-pages.yml: the committed releases.json is a valid fallback.
RUN bun run scripts/fetch-releases.ts || echo "keeping the committed releases.json"
RUN bun run build

FROM oven/bun:1-alpine AS docs
# docs' build script rewrites canonicals with perl, which alpine lacks.
RUN apk add --no-cache perl
WORKDIR /app/docs
COPY docs/package.json docs/bun.lock ./
RUN bun install --frozen-lockfile
COPY docs ./
RUN bun run build

FROM oven/bun:1-alpine
WORKDIR /app
COPY --from=web /app/web/out ./out
COPY --from=docs /app/docs/out ./out/docs
COPY web/serve.ts ./
USER bun
EXPOSE 3000
CMD ["bun", "serve.ts"]
