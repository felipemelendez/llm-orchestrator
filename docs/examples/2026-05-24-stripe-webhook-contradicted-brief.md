# Research brief: Stripe webhooks for `tenant_policy.updated` event

Date: 2026-05-24
Outcome: CONTRADICTED
Trigger point: A (pre-spec)
Stakes: high (vendor API + security-sensitive)
Libraries: Stripe, Next.js 14
Brief by: orch-researcher (1 researcher)

---

## Summary

- ⚠ Spec assumes: Stripe will deliver a custom webhook event named `tenant_policy.updated` to a Next.js 14 route handler.
- ⚠ Docs say (Stripe 2026-04-22.preview): Stripe webhooks only deliver Stripe's predefined event types (`payment_intent.*`, `customer.*`, `invoice.*`, `checkout.session.*`, etc.). There is no custom-event API that lets you emit `tenant_policy.updated` through Stripe's webhook infrastructure.
- Recommended revision: Clarify whether this is (a) a Stripe-native event being misnamed, (b) a domain event that should ride Stripe `metadata` piggybacked on an existing Stripe event, or (c) a non-Stripe internal webhook that shouldn't go through Stripe at all.
- Severity: Critical — the planned API surface (`tenant_policy.updated` from Stripe) does not exist.

---

## What was verified

### Stripe webhooks (vendor: Stripe; source: docs.stripe.com via WebFetch)

- Approach planned: receive a custom event `tenant_policy.updated` over a Stripe webhook
- Docs say: webhook event types must come from Stripe's predefined event-types list (snapshot events or thin events). No custom-event API exists.
- Status: ✗ contradicted

Citations:
- https://docs.stripe.com/webhooks (retrieved 2026-05-24)
- https://docs.stripe.com/api/events/types.md (retrieved 2026-05-24)

### Stripe webhook signature verification (source: docs.stripe.com via WebFetch)

- Approach planned: verify the inbound webhook with `stripe.webhooks.constructEvent(payload, sigHeader, endpointSecret)`
- Docs say: canonical Node.js API is unchanged at the current SDK; requires raw request body (not parsed JSON), `Stripe-Signature` header, endpoint secret in `whsec_...` format; scheme is HMAC-SHA256, `v1` signature only (ignore `v0`), default 5-minute timestamp tolerance.
- Status: ✓ matches (would be correct *if* the event existed)

Citations:
- https://docs.stripe.com/webhooks (retrieved 2026-05-24)

### Next.js 14 App Router webhook receiver (library: Next.js; source: Context7 `/vercel/next.js/v14.3.0-canary.87`)

- Approach planned: handle incoming POST in a Next.js 14 App Router `route.ts` `POST` handler
- Docs say: `await request.text()` returns the unparsed string suitable for `constructEvent`. No `bodyParser: false` opt-out needed (that config is Pages Router only). Recommended shape: `try { const text = await request.text(); /* verify + handle */ } catch { return new Response('Webhook error', { status: 400 }) }` returning 200 on success.
- Status: ✓ matches

Citations:
- Context7 `/vercel/next.js/v14.3.0-canary.87` route-handlers documentation (retrieved 2026-05-24)

---

## Recommended revision

**Before** (what the spec assumes):
```
Stripe webhook handler receives `tenant_policy.updated` event,
verifies signature, and updates the corresponding tenant record.
```

**After** (what current docs support — three options, depending on intent):

Option A — if the event source isn't actually Stripe:
```
Internal webhook handler at /api/internal/tenant-policy-updated receives
`tenant_policy.updated` from <whatever service actually emits it>,
verifies signature (using that service's verification scheme), and updates
the corresponding tenant record.
```

Option B — if this is a Stripe-billing event being renamed:
```
Stripe webhook handler receives `customer.subscription.updated` (the actual
Stripe event), verifies signature with stripe.webhooks.constructEvent,
extracts our tenant_id from event.data.object.metadata.tenant_id,
and updates the tenant's policy.
```

Option C — if it's a domain event the team wants Stripe to emit:
```
This isn't possible. Stripe doesn't emit custom event types. The spec
needs to choose a different transport (internal pub/sub, internal webhook
system, or piggyback domain data on a Stripe event's metadata).
```

**Why**: Stripe webhooks deliver only Stripe-defined events. The spec's named event `tenant_policy.updated` is not one of those. The signature-verification mechanics and the Next.js 14 route-handler pattern in the spec are both correct — only the event source is wrong.

**Severity**: Critical. The planned API surface (a Stripe webhook with a custom event name) does not exist. The plan would fail at the first webhook delivery test because Stripe simply never sends that event.

---

## Notes (lower-confidence observations)

- Stripe's API version reference at time of retrieval was `2026-04-22.preview` for the event-destinations API. Core webhook verification pattern was unchanged in the 2025/2026 SDK revisions.

---

## Sources

- https://docs.stripe.com/webhooks (retrieved 2026-05-24)
- https://docs.stripe.com/api/events/types.md (retrieved 2026-05-24)
- Context7 `/vercel/next.js/v14.3.0-canary.87` — App Router route handlers (retrieved 2026-05-24)

---

## How this brief was produced (meta — for the README pitch)

The user asked for "Stripe webhooks for the new tenant_policy update event." The classifier returned `RESEARCH_NEEDED` (vendor API + security-sensitive + architectural). The capability survey found Context7 connected but Stripe MCP not connected. The researcher emitted a parenthetical nudge ("Stripe MCP isn't connected; verifying against docs.stripe.com via WebFetch — continuing") and ran two parallel lookups: WebFetch on Stripe's webhook docs (for the vendor API question), and Context7 on `/vercel/next.js/v14.3.0` (for the Next.js route handler question). The Stripe lookup contradicted the spec's core assumption. The brief was written before any spec or plan was committed.

User intervention: zero.
Wall-clock: under 60 seconds.
What was saved: a feature that would have failed at the first webhook delivery test, because Stripe wasn't going to send that event — and nobody would have figured that out until the code shipped.
