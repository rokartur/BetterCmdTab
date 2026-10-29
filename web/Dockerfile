# syntax=docker/dockerfile:1
# Build context is the repo root: the image serves web/out, docs included.
FROM oven/bun:1-alpine AS web
WORKDIR /app/web
COPY web/package.json web/bun.lock ./
RUN bun install --frozen-lockfile
COPY web ./
# Non-fatal: the committed releases.json and repo.json are valid fallbacks when GitHub rate-limits the refresh.
# An optional build secret lifts the limit: docker build --secret id=GITHUB_TOKEN,env=GITHUB_TOKEN.
# A mount keeps the token out of the image history, which an ARG would not.
RUN --mount=type=secret,id=GITHUB_TOKEN,env=GITHUB_TOKEN \
    bun run scripts/fetch-releases.ts || echo "fetch-releases failed, building with the committed releases.json and repo.json"
RUN bun run build


FROM oven/bun:1-alpine
WORKDIR /app
COPY --from=web /app/web/out ./out
COPY web/serve.ts ./
USER bun
EXPOSE 3000
CMD ["bun", "serve.ts"]
