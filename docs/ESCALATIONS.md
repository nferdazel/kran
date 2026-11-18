# ESCALATIONS

Stop-and-ask log. An escalation exists because continuing would mean guessing about something the
owner or an advisor must decide. Resolved entries stay with the decision id that settled them; an
entry without a decision id is still open.

The six stop classes, and when work must halt rather than guess, are `AGENTS.md` §8. They are not
restated here: that section is the rule, this file is the record of entries it produced.

## How to escalate

1. Open an entry `E-xxx` with the next free number, using the template at the bottom of this file.
2. State the category from `AGENTS.md` §8, the task or decision affected, and the facts.
3. Attach evidence: files read, commands run with their output summary, and the exact lines or rows
   that establish the problem. A claim without evidence stays out of the entry.
4. Give two or three options, each with cost, risk, reversibility and the effect on a gate or a
   compliance tag. Name a recommendation, but do not mark it decided.
5. State exactly what is needed from the owner or advisor, and what stays blocked until then.
6. When a decision arrives, record it with its date and the `D-xxx` or `R-xx` id, and mark the entry
   resolved. If the decision changes a ruling, update `DECISIONS.md` in the same change.

If work is blocked but independent work exists, record the escalation, mark the affected task
`BLOCKED`, and continue on the independent item. Never mark a blocked task `DONE`.

---

## Log

| ID | Date | Category | Subject | Status | Decision |
|---|---|---|---|---|---|
| E-001 | 13 Oct 2026 | Open ADR (ADR-002, HTTP server) | Which HTTP server to use, after the spike showed that Mummy 0.4.8 cannot stream SSE and that its blocking handlers suit the synchronous database driver. The choice also forced the SSE-to-WebSocket deviation in the realtime specification. | Resolved 14 Oct 2026 | D-019 (option A: Mummy plus WebSocket, deviation approved and spec updated) |

### E-001 detail

- Task affected: T-014, which blocked the contract test, the realtime hub and the end-to-end task.
- Facts: Mummy 0.4.8 has no streaming API, so SSE would answer 501; measured throughput was 54,341
  requests per second against 46,094 for Prologue and 18,824 for a hand-rolled asyncnet server; Mummy
  calls handlers on a thread, which allows the synchronous PostgreSQL driver; Prologue would still
  need raw sockets for SSE.
- Options: A, Mummy plus WebSocket; B, hand-rolled asyncnet with SSE; C, Prologue, rejected because it
  does not close the SSE gap and carries the most dependencies.
- Needed from the owner: choose A or B; if A, approve the SSE-to-WebSocket deviation so the spec can be
  updated.
- Outcome: the owner chose A on 14 Oct 2026. The realtime endpoint stays
  `GET /api/v1/events/stream`, the resume token replaces `Last-Event-ID`, and the Mummy version bound
  and upgrade checklist live in D-037.

---

## Entry template

```
## E-xxx: <short title>
- Date:
- Category: <one of the six classes in AGENTS.md §8>
- Task or decision affected:
- Facts: <what was observed, with paths and lines>
- Evidence: <commands, output summary, source and date>
- Options: <A/B/C with cost, risk, reversibility, gate or tag impact>
- Recommendation: <one option, not marked decided>
- Needed from the owner: <the exact decision>
- Blocked until then: <tasks or scope>
- Outcome: <date, decision id, and what changed>
- Status: OPEN | RESOLVED (<date>)
```
