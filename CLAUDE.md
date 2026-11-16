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

## Where to look

No state is kept in this file. What runs and what is open: `README.md`
(commands, CI stages, deployment, versions) and the issues in
`18oe-workshop` (`bin/state` there). Design and plans: `18oe-workshop`'s
`notes/reference/` (start with `ui-spec.md` for the UI,
`infrastructure-plan.md` for the deployment).

Ruby/Sinatra/Puma engine and API, TypeScript frontend (`web/`), one Docker
image, deployed on Dokploy (`orient18oe`).

Browser runs (`bin/shot`, every `*-browser` test) take the machine-wide lock
`tmp/heavy.lock` of the main checkout; the full suite runs in GitHub Actions,
locally only targeted tests of the changed files (see the README).
