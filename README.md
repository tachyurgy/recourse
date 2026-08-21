# Recourse

A loan-servicing exception queue. Private lenders chase two things that eat their servicing
staff: payments that came back NSF, and loans coming up for renewal. Recourse is the work
queue for both — with an idempotent tape importer feeding it, an append-only event log
underneath it, and a language model reading inbound borrower replies into structured fields
that a person, not the model, turns into facts.

**Live:** https://recourse.levelbrook.com

## The four decisions worth arguing about

1. **A case has no `status` column.** Its state is a fold over its append-only event log,
   computed on read. A status column kept alongside an audit table can drift from it, nothing
   detects the drift, and it is discovered months later by a regulator. Deriving costs a query
   and removes the failure mode.

2. **Events are append-only and the database enforces idempotency.** `Event` raises on update
   and destroy. Replay protection is a unique index on `(lender_id, idempotency_key)`, not a
   read-then-write check that two concurrent workers both pass. The suite replays the same
   outreach fifty times and asserts one event.

3. **Imports are idempotent at the file and at the row.** Identical bytes for the same lender
   produce one `Import` and write nothing. Within a run, a row whose digest is unchanged is
   counted and not rewritten, so `updated_at` stays honest. The created/updated/unchanged
   counts are the reconciliation an operator reads before trusting the run.

4. **A model reading is evidence; only a person makes it a fact.** The classifier writes a
   `Reply` with a typed intent, a confidence, and the verbatim span it relied on. It never
   writes an event, schedules a draft, or closes a case.

## Why decision 4 is not just caution

The repo carries a 40-case labelled set and a recorded eval run. The rules baseline scores
47.5%. `gemini-3.6-flash` under a response schema scores 97.5% — and its one miss is the
one that matters:

> "I can do 300 a month, that is genuinely all I have. Take it or take the house."

Read as **promise_to_pay** at **80% confidence**. It is a hardship. Acting on it schedules a
draft that returns and charges another NSF fee to the borrower least able to absorb one —
the exact harm the product exists to reduce. Because the confidence is high, a threshold rule
lets it through. Only the promotion boundary catches it.

The first thirty cases scored 30/30, which meant the set had stopped discriminating rather
than that the problem was solved; ten adversarial cases were added and accuracy fell to a
number worth having.

## Structured output, and two guards on it

The model is constrained by a response schema, so callers get a typed object or an error,
never prose to regex. An intent outside the enum is a recorded failure, not coerced.

Both actionable fields are then re-derived from the borrower's own text: an amount survives
only if its digits appear in the email, a date only if the email contains a date-shaped token.
A confidently invented figure dies here. When the upstream fails — as it did during this
build, on a model deprecation — the classifier degrades to the deterministic baseline and
records the error string on the reply rather than dropping it.

## Stack

Rails 8.1, PostgreSQL, Hotwire, importmap, no build step. 37 tests / 251 assertions.

```bash
bin/rails db:prepare db:seed
bin/rails test
bin/rails eval:run          # re-records db/eval/last_run.json
bin/rails s
```

`GEMINI_API_KEY` enables the model path. Without it the deterministic baseline answers and
everything still runs, which is also what makes the eval's baseline column meaningful.

The recorded eval lives in `db/eval/last_run.json` on purpose: it is reviewable in a diff, so
a regression in the numbers shows up in a pull request instead of in production.

## Data

All synthetic. No real borrower information is present anywhere in this repository.
