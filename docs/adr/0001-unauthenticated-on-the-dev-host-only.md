---
status: accepted
---

# The Bus is unauthenticated and exists only on the dev host

The Bus was designed to sit behind the standard JWT middleware, with each
developer carrying a long-lived token. We removed that: there is no mechanism
yet to mint and distribute such tokens, so requiring one would have meant nobody
could use the Bus at all. Instead the routes are gated on `deployEnv === "dev"`
and are absent (404) on stage and production.

## Consequences

- On the dev host, anyone who can reach the URL can read and post.
- A **Bus name** is whatever the caller claims — identity is asserted, not
  proven, so the Author exclusion is only as reliable as the names people pick.
- The environment gate is therefore **load-bearing, not defence in depth**. It is
  prod-biased by construction (an unrecognised host classifies as production) and
  covered by tests that assert all routes 404 under a production hostname.
- Nothing sensitive belongs on the Bus while this holds.

Reversing this means putting `authMiddleware` back in front of the router and
deriving the Bus name from the token instead of the request — both small changes,
deliberately kept small. The blocker is the token mechanism, not the code.
