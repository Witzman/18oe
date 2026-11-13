# Two stages (#41, notes/reference/infrastructure-plan.md in 18oe-workshop):
# a Node stage bundles the browser app into web/dist, the Ruby stage ships the
# engine, the API and that bundle. Node, npm and the web sources never reach
# the final image.

# --- Stage 1: frontend bundle -------------------------------------------------
# web/build.mjs imports TypeScript directly (themes/*.ts): Node >= 22.18.
FROM node:22.23-alpine AS web
WORKDIR /build

COPY web/package.json web/package-lock.json ./web/
RUN cd web && npm ci --no-audit --no-fund

COPY web/ ./web/
# build.mjs reads the roadmap version from ../VERSION.
COPY VERSION ./VERSION
RUN cd web && NODE_ENV=production npm run build

# --- Stage 2: runtime ---------------------------------------------------------
FROM ruby:3.3-alpine

WORKDIR /app

# Build tools only for compiling gems with native extensions; removed again in
# the same layer so they do not stay in the image.
COPY Gemfile Gemfile.lock ./
# Test gems (rspec, rack-test) are not needed in the image.
ENV BUNDLE_WITHOUT=test
RUN apk add --no-cache --virtual .build-deps build-base \
 && bundle install \
 && apk del .build-deps

COPY VERSION app.rb ./
COPY lib/ ./lib/
COPY --from=web /build/web/dist ./web/dist

ENV PORT=80 DATABASE_PATH=/data/18oe.sqlite3
VOLUME /data
EXPOSE 80

# /healthz answers 503 (status "degraded") when the database is not writable.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1/healthz | grep -q '"status":"ok"' || exit 1

CMD ["ruby", "app.rb"]
