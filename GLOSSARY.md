# Domain glossary

## Session grid

The ordered exercise snapshots and their live Set entries for one non-deleted
workout session, including optional references to eligible previous completed
exercises. Watch and fresh read share this complete-grid contract. Missing or
deleted sessions have an empty grid; deleted exercises and Set entries are
excluded, while live exercises with no live sets remain present.

## Set entry

One numbered set belonging to a Session exercise. Timed exercises currently
store seconds in its reps field.

## Set-entry draft

The unsaved editable values for a Set entry during one sheet opening.

## Rest timer

The single active persisted wall-clock rest countdown for the current local
profile, with optional Session exercise context. Its saved deadline and label
drive the countdown and alert adapters. An elapsed deadline remains present
until the Rest timer is replaced or dismissed.
