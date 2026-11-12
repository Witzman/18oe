# 18oe

Turn-based 18xx-style train game. Private project; process and design docs
live in the sibling `18oe-workshop` repo, not here — see `CLAUDE.md` for
the short version and the pointer.

## Local development

```sh
bin/setup   # gems into vendor/bundle, Node 22 into .tools/node (idempotent)
bin/test    # runs the test suites (rspec for now)
```

Docker is not required for tests. Everything stays inside the repo
(`vendor/bundle`, `.tools`, both gitignored); `bundle` and `node` need not
be in `PATH`.

## Running with Docker

```sh
docker compose up --build
curl http://localhost/healthz
```

## Deployment

Runs on Dokploy (`orient18oe`), building this repo's `Dockerfile`/
`docker-compose.yml` directly. DNS/vhost routing (the server also runs
Apache for other domains) is being finished separately.

## Status

Walking skeleton only — `app.rb` answers `/healthz`, no game logic yet.
Ruby, Sinatra, Puma.
