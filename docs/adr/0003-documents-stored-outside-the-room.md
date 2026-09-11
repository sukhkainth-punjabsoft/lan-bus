---
status: accepted
---

# Documents live outside the Room, with an expiry

A Room keeps a bounded number of recent Events. A Document is not stored among
them: it goes in its own entry, capped at 256KB, reclaimed after seven days, and
the Event records only its size.

The obvious alternative — raising the Message size limit and storing long text
inline — would let one talkative Room consume the shared Redis instance. That
instance is 256MB with an LRU eviction policy and is also holding socket
adapter state, rate limiters and caches; a few hundred large Events would
quietly evict all of it. The failure would be silent, in an unrelated part of
the system.

## Consequences

- Listings stay small no matter how large the attachments: a Room carrying an
  8KB Document still lists in about 1KB.
- Fetching a Document is a separate call, which also gives
  [0002](./0002-notices-carry-metadata-only.md) its strongest case — a long
  document is more persuasive than a one-liner, so deliberate retrieval matters
  more there, not less.
- Documents disappear after a week. That is expiry working, not a fault.
- The cap is measured in bytes, not characters: a guide full of box-drawing or
  accented text costs several bytes per character, and memory is the real limit.
