# 18oe — context

Small on purpose. The *why* lives in the sibling `18oe-workshop` repo
(issues, research, design docs) — this file only orients someone who opened
this repo on its own.

## What this is

A private, turn-based digital implementation of *On the Rails of the
Orient Express* (an 18xx-family train game). Only what ships lives here —
no process files, no notes, no specs. That's `18oe-workshop`'s job.

## Rules

1. **Changes only through a pull request** from a feature branch, never a
   direct push to `main` — GitHub branch protection enforces this.
2. **No `Co-Authored-By` and no "Generated with" line** in commits, PR
   descriptions or tags.
3. **The design/why for any change is a `18oe-workshop` issue**, not a
   comment here. If you're not sure why something is the way it is, look
   there first.

## Current state

Walking skeleton only — `app.rb` answers `/healthz`, no game logic yet.
Ruby/Sinatra/Puma, one Docker image, deployed on Dokploy (`orient18oe`).
See `18oe-workshop`'s `notes/reference/infrastructure-plan.md` and
`frontend-plan.md` for where this is going.

```sh
docker compose up --build
curl http://localhost/healthz
```
