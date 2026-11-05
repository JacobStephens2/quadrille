# Domain glossary

## Local profile

The named local database namespace, either guest (`quadrille_local`) or
per-account (`quadrille_user_<account id>`).

## Account sync

Reconciling workout rows between one verified account and its matching Local
profile. One action retains its owner throughout and becomes obsolete when
its ownership generation changes. Device settings, credentials, and Rest
timers are excluded from the payload.

## Session grid

The ordered exercise snapshots and their live Set entries for one non-deleted
workout session, including optional references to eligible previous completed
exercises. Watch and fresh read share this complete-grid contract. Missing or
deleted sessions have an empty grid; deleted exercises and Set entries are
excluded, while live exercises with no live sets remain present.

## Session ending

Finishing or discarding one workout session within its invoking Local profile,
retaining that ownership through Rest timer cancellation, session persistence,
and any automatic Account sync submission.

## Set entry

One numbered set belonging to a Session exercise. Timed exercises currently
store seconds in its reps field.

## Exercise history

Completed Set entries for a case-insensitively matched Session exercise display
name within one Local profile, grouped by completed workout session newest
first, together with personal records computed from the same live rows.
Deleted sessions, Session exercises, and Set entries contribute nothing.

## Set-entry draft

The unsaved editable values for a Set entry during one sheet opening. Each
opening retains its invoking Local profile and database generation.

## Set entry logging

Saving a Set-entry draft as completed or skipped, publishing its next-set
recommendation and optionally starting its Rest timer within the invoking
Local profile. The opening becomes obsolete when that Local profile or
database generation changes.

## Rest timer

The single active persisted wall-clock rest countdown for the current local
profile, with optional Session exercise context. Its saved deadline and label
drive the countdown and alert adapters. An elapsed deadline remains present
until the Rest timer is replaced or dismissed.
