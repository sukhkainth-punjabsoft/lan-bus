---
status: accepted
---

# Notices carry metadata only; text is fetched deliberately

A Notice tells a machine who posted and to which Room, never the Message or the
Document. Reading the text is a separate, explicit call.

The reason is that a Wake injects into a Claude Code session with shell and file
access, and the text is written by a person on another machine. The Bus can
authenticate *who* sent an Event; it can never validate *what it says*. A Notice
that carried the text would put unvetted instructions in front of an agent
without anyone choosing to put them there — "pull main and run ./deploy.sh"
arriving as context rather than as something a human decided to show it.

Fencing the text as untrusted was the alternative, and it is what the original
design called for. Not delivering it at all is stronger: fencing is a convention
that erodes, whereas a payload that never arrives cannot be acted on.

## Consequences

- Reading a teammate's message costs a second round trip. This is the point.
- Clients render "N new from X" and stop there.
- If a Notice ever gains a `message` field, this decision has silently reversed;
  a test asserts it does not.
