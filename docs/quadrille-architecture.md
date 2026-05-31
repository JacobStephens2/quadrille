# Prompt

A weightlifting app which is a cross-platform Flutter/Dart application which will have apps for web, iOS, watchOS, and Android.

---

What about a weightlifting app? Right now I bring a grid on paper of my exercises for that day, such as pull day 1, with a list of exercises down the left - each with notes about how much rest to leave between sets, and columns for each row including weight and reps. I wanted an app for this partly to reduce my need to copy over my list of exercises when I fill the sheet out, but also because I wanted the app to have the rest timers integrated or preset / easier to use than custom timers on my watch.

I attached images of the seven sheets of paper I recently used to track my weekly workout routine. These can help track what the app needs to be able to track and do.

---

I'm naming the app Quadrille, and I registered quadrille.app for it.

Create an architecture plan for this Dart / Flutter web, iOS, watchOS, and Android application.

# Perplexity Model Council Answer

### 1. Where Models Agree

| Finding | GPT-5.5 Thinking | Claude Opus 4.8 Thinking | Gemini 3.1 Pro Thinking | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| Use **local-first** persistence; DB is source of truth | ✓ | ✓ | ✓ | Gym/offline reality; Drift/SQLite as primary store.[^3_1][^3_2][^3_3] |
| Use **MVVM + Repository pattern** (Views→VMs→Repos→Services) | ✓ | ✓ | ✓ | All propose separation of concerns and repository abstraction.[^3_1][^3_2][^3_3] |
| Use **Riverpod** for state + DI, and **go_router** for navigation | ✓ | ✓ | ✓ | Riverpod recommended as modern default; go_router/GoRouter for routing.[^3_1][^3_2][^3_3] |
| Model rest timer as **wall-clock deadline (`endsAt`)**, not tick countdown | ✓ | ✓ | ✓ | Store `endsAt`; compute remaining; survives background/process death.[^3_1][^3_2][^3_3] |
| Use OS scheduling via **local notifications** for reliable “rest done” | ✓ | ✓ | ✓ | `flutter_local_notifications` + timezone scheduling; don’t rely on background Dart.[^3_1][^3_2][^3_3] |
| watchOS requires a **native SwiftUI companion** + connectivity bridge | ✓ | ✓ | ✓ | Flutter doesn’t build to watchOS; bridge via WatchConnectivity + platform channels.[^3_1][^3_2][^3_3] |

### 2. Where Models Disagree

| Topic | GPT-5.5 Thinking | Claude Opus 4.8 Thinking | Gemini 3.1 Pro Thinking | Why They Differ |
| :-- | :-- | :-- | :-- | :-- |
| watchOS in v1 vs later | Build as Phase 4 (after timers) | Defer to v3; phone notifications already buzz Apple Watch | Defer to Phase 5; stretch goal | Different weighting of complexity vs value; Claude emphasizes Xcode target fiddliness and “80% value” from notifications.[^3_2][^3_3] |
| Monorepo/packages vs single app | Explicit monorepo with `packages/` (core/data/timer) | Feature-first inside `lib/` (domain optional per feature) | Feature-first inside `lib/` | GPT-5.5 optimizes for clean boundaries via packages; others keep it simpler while still modular.[^3_1][^3_2][^3_3] |
| Sync strategy (future) | Export/import v1; optional Supabase later | Suggests PowerSync+Supabase as best local-first sync later | Mentions web notifications permissions; sync not central | Different emphasis: Claude plans explicitly for local-first sync tooling; Gemini stays MVP-focused.[^3_2][^3_3] |

### 3. Unique Discoveries

| Model | Unique Finding | Why It Matters |
| :-- | :-- | :-- |
| Claude Opus 4.8 Thinking | Strong recommendation to treat **OS alarms + watch surface as “native edges”** and keep Flutter core clean.[^3_2] | Helps you draw crisp boundaries and avoid “half-native” complexity creep. |
| GPT-5.5 Thinking | Concrete **deadline-based timer repository + controller API** plus watch command/event flow design.[^3_1] | Gives you implementable interfaces early (less refactor later). |
| Gemini 3.1 Pro Thinking | Emphasis on building the **grid UI with dummy data first** (UX-first), then persistence/timers.[^3_3] | Reduces risk: the grid interaction is your product; validate it before backend work. |

### 4. Comprehensive Analysis

**High-Confidence Findings.** The most stable architecture choice for Quadrille is a **local-first Flutter core** with a typed local database (Drift/SQLite), and a strict separation between UI and data access using **MVVM + repositories**. This matches your “paper quadrille grid” workflow: templates generate sessions; sessions contain ordered exercises; each exercise contains set entries (weight/reps) and metadata like rep targets, notes, and rest intervals. Because all models converge here, it’s a safe bet that you’ll avoid the two common failure modes of workout apps: (1) logic leaking into widgets, and (2) data models that can’t evolve once you add “superset groups,” unilateral sets, pain flags, or machine notes.[^3_1][^3_2][^3_3]

The second high-confidence piece is the timer design. All three models insist you should persist timers as **absolute deadlines (`endsAt`)**, not as “seconds remaining,” and drive UI countdowns by recomputing `endsAt - now`. This is crucial for gym usage: the app will be backgrounded, screens will lock, and processes can be killed. Storing a deadline makes the timer resilient, and scheduling an OS-level local notification at `endsAt` is the reliable way to produce sound/haptics when the phone is in your pocket.[^3_2][^3_3][^3_1]

Finally, all models agree on the platform truth: **Flutter does not target watchOS**, so a watch experience requires a **native SwiftUI watch app** (companion), with **WatchConnectivity** bridged through iOS native code and Flutter platform channels (or a plugin wrapper). That means you should design Quadrille as “Flutter owns the source of truth,” and the watch is a thin remote display/control surface.[^3_3][^3_1][^3_2]

**Areas of Divergence.** The main practical decision is **when** to build watchOS. Claude Opus 4.8 Thinking argues strongly to defer it because scheduled iOS notifications already surface on Apple Watch, giving most of the benefit without building and maintaining a watch target. GPT-5.5 Thinking and Gemini 3.1 Pro Thinking also place it after the phone experience is solid, but are a bit more optimistic about adding it as a defined later phase. The correct choice depends on your goal: if Quadrille is primarily a daily driver quickly, defer watchOS; if the watch integration is a core learning objective, schedule it once timers + notifications are rock-solid and your “active session” model is stable.[^3_1][^3_2][^3_3]

The second divergence is structural: GPT-5.5 Thinking recommends a monorepo with separate Dart packages (`quadrille_core`, `quadrille_data`, `quadrille_timer`) to enforce boundaries. Claude and Gemini suggest a feature-first layout under `lib/` with domain/data/presentation subfolders. Both can be excellent. In practice, a hybrid works well: start feature-first in one Flutter app repo; extract packages once boundaries stabilize (or if you want the portfolio story of a clean modular core).[^3_2][^3_3][^3_1]

**Unique Insights Worth Noting.** Claude’s framing of “native edges” is the right mental model: Quadrille should feel like a Flutter app everywhere, with deliberate, small native bridges only where the OS demands it (notification scheduling exactness, WatchConnectivity, haptics). GPT-5.5’s proposed interfaces for timer/watch flows are valuable because they force you to define what the “active workout snapshot” is, which later makes watch + widgets + potential sync much easier. Gemini’s suggestion to prototype the grid UI with fake data first is also high-leverage: the grid interaction (fast entry, auto-advance, sticky columns on web) is the differentiator; validate that before deep database work.[^3_3][^3_1][^3_2]

**Recommendations.** Build Quadrille as a **local-first Flutter app (web/iOS/Android)** using **Riverpod + go_router + Drift**, with a **deadline-based timer engine** that schedules **local notifications** at `endsAt` and persists timer state; treat watchOS as a **native SwiftUI companion** added after v1 timers/history are stable (or earlier only if it’s a primary learning milestone). If you want, I can turn this into a concrete repo skeleton (folders, Riverpod provider graph, Drift tables/migrations, and the exact “Start session from template → log set → start timer” flow).[^3_1][^3_2][^3_3]
<span style="display:none">[^3_10][^3_11][^3_12][^3_13][^3_14][^3_15][^3_16][^3_17][^3_18][^3_19][^3_20][^3_21][^3_22][^3_23][^3_24][^3_25][^3_26][^3_27][^3_28][^3_29][^3_30][^3_31][^3_32][^3_33][^3_34][^3_35][^3_36][^3_37][^3_38][^3_39][^3_4][^3_40][^3_41][^3_42][^3_43][^3_44][^3_45][^3_46][^3_5][^3_6][^3_7][^3_8][^3_9]</span>

<div align="center">⁂</div>

[^3_1]: Day-1-Push-A.jpg

[^3_2]: Day-3-Leg-A-3.jpg

[^3_3]: Day-2-Pull-A-2.jpg

[^3_4]: https://dinkomarinac.dev/blog/building-local-first-flutter-apps-with-riverpod-drift-and-powersync/

[^3_5]: https://supabase.com/blog/offline-first-flutter-apps

[^3_6]: https://stackoverflow.com/questions/59480124/how-to-run-clock-timer-in-background-on-flutter

[^3_7]: https://cheesecakelabs.com/blog/flutter-apps-apple-watch-integration/

[^3_8]: https://stackoverflow.com/questions/73770044/flutter-apple-watch-unable-to-resolve-product-type-com-apple-product-type-w

[^3_9]: https://docs.flutter.dev/app-architecture/recommendations

[^3_10]: https://docs.flutter.dev/app-architecture/guide

[^3_11]: https://dev.to/techwithsam/clean-architecture-in-flutter-2026-practical-implementation-guide-1dfb

[^3_12]: https://softaims.com/blog/flutter-production-architecture-clean-code-2026

[^3_13]: https://softaims.com/blog/flutter-state-management-riverpod-bloc-2026

[^3_14]: https://samioda.com/en/blog/flutter-state-management-2026

[^3_15]: https://foresightmobile.com/blog/best-flutter-state-management

[^3_16]: https://sharpskill.dev/en/blog/flutter/flutter-state-management-2026-riverpod-bloc-getx

[^3_17]: https://github.com/simolus3/drift/issues/3440

[^3_18]: https://stackoverflow.com/questions/78626240/flutter-drift-for-the-web-unsupported-operation-unsupported-invalid-type-invali

[^3_19]: https://www.reddit.com/r/flutterhelp/comments/1hx8m6t/is_there_a_way_to_keep_algorithms_running_even/

[^3_20]: https://www.reddit.com/r/flutterhelp/comments/1rjb8be/how_to_make_flutter_notifications_fire_reliably/

[^3_21]: https://asoasis.tech/articles/2026-03-19-2054-flutter-local-notifications-scheduling-guide/

[^3_22]: https://zenn.dev/koji_1009/articles/28ddc9ec95d803?locale=en

[^3_23]: https://github.com/MaikuB/flutter_local_notifications/issues/2185

[^3_24]: https://www.reddit.com/r/flutterhelp/comments/1mlkfaj/flutterios_timer_notification_sounds_dont_play/

[^3_25]: https://github.com/theamorn/flutter-apple-watch

[^3_26]: https://pub.dev/packages/watch_connectivity

[^3_27]: https://pub.dev/documentation/flutter_watch_os_connectivity/latest/

[^3_28]: https://www.reddit.com/r/flutterhelp/comments/1qdt2wa/flutter_ios_app_native_watchos_companion_not/

[^3_29]: https://www.reddit.com/r/FlutterDev/comments/y7ed56/apple_watch_flutter_no_problem_fluttervikings_2022/

[^3_30]: https://docs.powersync.com/client-sdks/frameworks/flutter-web-support

[^3_31]: https://www.reddit.com/r/FlutterDev/comments/1jr64rh/syncable_offlinefirst_multidevice_sync_with_drift/

[^3_32]: https://dev.to/dhruvjoshi9/flutter-web-with-wasm-what-actually-changes-for-developers-3k51

[^3_33]: https://startup-house.com/blog/flutter-app-best-practices

[^3_34]: https://stackoverflow.com/questions/79128897/how-to-implement-schedule-background-notification-in-flutter

[^3_35]: https://foresightmobile.com/blog/whats-new-in-flutter-mobile-development

[^3_36]: https://app.daily.dev/posts/clean-architecture-in-flutter-2026---practical-implementation-guide-lqimgmbbf

[^3_37]: https://www.freecodecamp.org/news/how-to-use-local-notifications-in-flutter/

[^3_38]: https://github.com/ThaysPrado/Todo-App-with-Apple-Watch-Integration

[^3_39]: https://www.facebook.com/groups/fluttervn/posts/2128929727643454/

[^3_40]: https://blog.devgenius.io/create-a-countdown-timer-that-runs-if-the-app-is-closed-e5501598e16d

[^3_41]: https://powersync.com/blog/flutter-tutorial-building-an-offline-first-chat-app-with-supabase-and-powersync

[^3_42]: https://community.flutterflow.io/community-tutorials/post/offline-first-flutterflow-apps-with-powersync-and-supabase-guide-DQyHPTnAycU33ok

[^3_43]: https://pub.dev/packages/flutter_advanced_countdown/versions/1.0.2/changelog

[^3_44]: https://www.reddit.com/r/FlutterDev/comments/1oz92em/which_architecture_is_best_bloc_or_riverpod_as_a/

[^3_45]: https://sharpskill.dev/en/blog/flutter/flutter-state-management-riverpod-vs-bloc

[^3_46]: https://flutterstudio.dev/blog/bloc-vs-riverpod.html

# GPT 5.5 Thinking

Quadrille Architecture Plan
Quadrille should be architected as a local-first, template-driven lifting log with deadline-based rest timers, built primarily in Flutter/Dart for web, iOS, and Android, with a native SwiftUI watchOS companion for wrist-based countdowns, haptics, and quick set controls.

The important framing: this is not “a generic workout social app.” It is a digital version of your paper quadrille-grid workflow:

reusable Push/Pull/Legs templates

ordered exercises

A/B grouped movements / supersets

target rep ranges

per-exercise rest intervals

notes like pain, wait/unavailable, bench height, machine settings, grip notes

session history by date

weight × reps logging per set

timer auto-start after a logged set

watch-friendly “how long until next set?” feedback

So the architecture should keep the grid/session model at the center.

1. Platform Strategy
Primary shared app
Use Flutter for:

Web

iOS

Android

This codebase owns:

UI

routing

domain logic

persistence

workout templates

session logging

rest timer orchestration

local notifications

history and analytics

watchOS companion
Use a native SwiftUI watchOS app, not Flutter.

Flutter does not meaningfully support watchOS as a first-class target. The right architecture is:

text
Flutter iOS App
   ↓ native bridge
iOS WatchConnectivity Bridge
   ↓
SwiftUI watchOS App
The watch app should be a companion surface, not a full independent app at first.

V1 watchOS responsibilities:

show active rest timer

show current exercise / set

show next exercise

haptic when rest ends

quick controls:

Done / next set

Skip rest

+30s

-15s

pause/resume maybe later

The iPhone remains the source of truth.

2. High-Level Architecture
Use a pragmatic layered architecture:

text
apps/
  quadrille_flutter/          # Flutter app: web, iOS, Android
  quadrille_watchos/          # SwiftUI watch app target, likely inside ios/

packages/
  quadrille_core/             # Pure Dart domain models, value types, rules
  quadrille_data/             # Drift database, repositories, migrations
  quadrille_timer/            # Timer engine, deadline logic, notifications interface
Within the Flutter app:

text
lib/
  app/
    quadrille_app.dart
    router.dart
    theme/
    bootstrap.dart

  features/
    templates/
    sessions/
    active_workout/
    timer/
    history/
    exercises/
    settings/
    import_export/

  shared/
    widgets/
    grid/
    forms/
    platform/
    utils/
The key design principle:

Business logic should not live in widgets. Widgets render state; providers/controllers mutate state; repositories persist state; pure domain objects describe the workout.

3. Recommended Stack
Flutter app
Concern	Recommendation
State management	riverpod / flutter_riverpod
Routing	go_router
Local database	drift
Native SQLite	sqlite3_flutter_libs
Web database	Drift web backend / IndexedDB-compatible storage
Immutable models	freezed or Dart 3 sealed/value classes
JSON serialization	json_serializable
Local notifications	flutter_local_notifications
Time zones	timezone
Haptics	Flutter HapticFeedback plus native watch haptics
Charts later	fl_chart or custom painter
Logging	talker, logger, or simple structured logger
Testing	flutter_test, test, mocktail, golden tests selectively
Native iOS/watchOS
Concern	Recommendation
watchOS UI	SwiftUI
iPhone/watch communication	WatchConnectivity
Flutter/native bridge	MethodChannel + EventChannel
Watch haptics	WKInterfaceDevice.current().play(...)
Watch persistence	tiny local cache only, likely UserDefaults or simple file
4. Data Model
The model should distinguish between:

Templates — reusable plan, e.g. “Day 1 Push A”

Sessions — one performed workout from a template

Exercise definitions — canonical movements

Session exercise instances — what appeared in that session

Set logs — actual weight/reps/pain/completion data

Timers — active or historical rest intervals

Notes/events — pain, machine unavailable, locker start/end, etc.

Core entities
WorkoutTemplate
Represents something like:

Day 1 Push A

Day 2 Pull A

Day 3 Legs A

Day 4 Push B

Day 5 Pull B

Day 6 Legs B

Day 7 Rest

dart
class WorkoutTemplate {
  final TemplateId id;
  final String name; // "Day 1 Push A"
  final int sortOrder;
  final String? description;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;
}
TemplateExercise
Represents a row in your paper sheet.

Important because your paper rows include:

order numbers: 1, 2A, 2B, 3A, 3B

exercise name

target sets

target rep range

rest time

notes

sometimes equipment settings

sometimes unilateral left/right behavior

dart
class TemplateExercise {
  final TemplateExerciseId id;
  final TemplateId templateId;

  final String orderLabel; // "1", "2A", "2B", "3A"
  final int sortIndex;

  final ExerciseId? exerciseId;
  final String displayName; // denormalized for easy editing

  final int targetSets;
  final RepTarget repTarget;
  final Duration rest;

  final String? notes; 
  // e.g. "bench 8", "90s", "2.5'", "1/4 height", "P = pain"

  final ExerciseGroup? group;
  // for supersets / paired movements: "2", "3", etc.

  final bool isUnilateral;
  final LoadTrackingMode loadTrackingMode;
}
Exercise
Canonical exercise library.

dart
class Exercise {
  final ExerciseId id;
  final String name; // "Barbell Bench Press"
  final ExerciseCategory category; // push, pull, legs, core, etc.
  final MuscleGroup? primaryMuscle;
  final EquipmentType? equipment;
  final bool archived;
}
You do not need a huge exercise ontology in V1. Start with your own exercises.

WorkoutSession
An actual workout on a specific date.

dart
class WorkoutSession {
  final SessionId id;
  final TemplateId? templateId;
  final String name; // copied from template at session creation
  final DateTime startedAt;
  final DateTime? completedAt;

  final SessionStatus status;
  final String? generalNotes;

  final DateTime createdAt;
  final DateTime updatedAt;
}
SessionExercise
Snapshot of each exercise row during a workout.

This should be copied from the template when the session starts, so future template edits do not mutate history.

dart
class SessionExercise {
  final SessionExerciseId id;
  final SessionId sessionId;

  final String orderLabel;
  final int sortIndex;
  final String displayName;

  final int plannedSets;
  final RepTarget plannedRepTarget;
  final Duration plannedRest;

  final String? plannedNotes;
  final String? sessionNotes;

  final ExerciseGroup? group;
  final bool isUnilateral;
  final LoadTrackingMode loadTrackingMode;
}
SetEntry
The core log cell.

Your sheets effectively track:

set number

weight

reps

sometimes bodyweight

sometimes left/right reps

sometimes pain

sometimes skipped/unavailable/wait

sometimes notes

dart
class SetEntry {
  final SetEntryId id;
  final SessionExerciseId sessionExerciseId;

  final int setNumber;

  final double? weight;
  final WeightUnit weightUnit; // lb initially

  final int? reps;
  final int? leftReps;
  final int? rightReps;

  final SetStatus status;
  // completed, skipped, warmup, failed, partial, unavailable

  final Rpe? rpe;
  final PainLevel? pain;

  final String? notes;

  final DateTime? startedAt;
  final DateTime? completedAt;

  final DateTime createdAt;
  final DateTime updatedAt;
}
For V1, you can keep this simpler:

dart
weight
reps
notes
completedAt
But the schema should leave room for unilateral and special cases.

RestTimerState
Do not model timers as “counting down every second” in persistence.

Model them as a deadline.

dart
class ActiveRestTimer {
  final SessionId sessionId;
  final SessionExerciseId sessionExerciseId;
  final SetEntryId? afterSetEntryId;

  final DateTime startedAt;
  final Duration duration;
  final DateTime endsAt;

  final TimerStatus status;
}
The UI computes:

dart
remaining = endsAt.difference(now)
This is more reliable across:

screen lock

app backgrounding

web tab suspension

Android/iOS lifecycle changes

watch sync

process death

5. Database Design
Use Drift as the persistence layer.

Suggested tables:

text
workout_templates
template_exercises
exercises

workout_sessions
session_exercises
set_entries

active_timer
timer_events

session_notes
app_settings
schema_metadata
Important database behavior
When starting a session from a template:

text
WorkoutTemplate
  → WorkoutSession

TemplateExercise rows
  → copied into SessionExercise rows
This gives you immutable historical accuracy.

If you later change “Push A” from 3 sets to 4 sets, older sessions remain as they were.

6. Feature Modules
6.1 Templates Feature
Responsible for:

create/edit workout templates

reorder exercises

add A/B group labels

configure target sets

configure target rep ranges

configure rest durations

add notes

duplicate templates

archive templates

Screens:

text
/templates
/templates/:id
/templates/:id/edit
/templates/:id/exercises/:templateExerciseId/edit
V1 UI should make it easy to recreate your current sheets.

Example template row:

text
2A  Chest-supported row
    8–12 reps · 2:00 rest · bench 4
6.2 Active Workout Feature
This is the core app.

Screens:

text
/start
/session/:id
/session/:id/grid
/session/:id/exercise/:sessionExerciseId
Primary interaction:

Select “Day 2 Pull A”

Start session

See grid

Tap a set cell

Enter weight/reps

Save

Rest timer auto-starts

Notification/watch haptic fires

Continue

The active workout screen should offer two layouts:

Phone layout
Card/list optimized:

text
Current Exercise
Set 2 of 4
Weight [____] Reps [____]
[Save Set]

Rest: 01:24
Tablet/web layout
Grid optimized:

text
Exercise              Set 1      Set 2      Set 3      Set 4
Barbell bench press   115 x 8    120 x 6    ___        ___
Overhead press        50 x 10    ___        ___
Lateral raise         10 x 12    ___        ___
Given the app’s name, the grid should be a first-class UI component.

6.3 Timer Feature
The timer module should be platform-aware but domain-simple.

Domain API:

dart
abstract interface class RestTimerController {
  Future<void> startRestTimer({
    required SessionId sessionId,
    required SessionExerciseId exerciseId,
    required Duration duration,
    SetEntryId? afterSetId,
  });

  Future<void> cancelTimer();

  Future<void> extend(Duration delta);

  Stream<RestTimerSnapshot> watchTimer();
}
Internally:

text
Dart timer state
  ↓
persistent active_timer row
  ↓
platform notification scheduler
  ↓
watch bridge update
Timer rule
When a set is completed:

dart
await setRepository.saveSet(entry);
await timerController.startRestTimer(
  sessionId: sessionId,
  exerciseId: exerciseId,
  afterSetId: entry.id,
  duration: exercise.plannedRest,
);
The timer’s correctness should come from:

dart
endsAt = startedAt + duration
not from an in-memory countdown.

6.4 History Feature
Screens:

text
/history
/history/:sessionId
/history/exercise/:exerciseId
V1 history:

list sessions by date

view completed grid

copy previous weights into a new session

inspect prior performance for an exercise

V2 history:

estimated 1RM

volume

progression over time

PRs

missed reps

rest adherence

pain notes

6.5 Exercise Library Feature
V1 can be minimal.

Screens:

text
/exercises
/exercises/:id
/exercises/:id/edit
Fields:

name

category

equipment

default rest

default rep target

default notes

6.6 Settings Feature
Include:

weight unit: lb/kg

default rest duration

timer sound

vibration/haptics

auto-start timer after set

keep screen awake during workout

export data

import data

backup location later

watch integration status

7. State Management Plan
Use Riverpod providers grouped by feature.

Example:

text
templateRepositoryProvider
sessionRepositoryProvider
activeSessionProvider(sessionId)
activeTimerProvider
sessionGridControllerProvider(sessionId)
exerciseHistoryProvider(exerciseId)
settingsProvider
Pattern
Use:

repositories for persistence

controllers/notifiers for mutations

providers for derived state

widgets as thin renderers

Example:

dart
final activeSessionControllerProvider =
    AsyncNotifierProvider.family<ActiveSessionController, ActiveSessionViewModel, SessionId>(
  ActiveSessionController.new,
);
ActiveSessionViewModel can flatten the session into UI-friendly shape:

dart
class ActiveSessionViewModel {
  final WorkoutSession session;
  final List<ExerciseGridRow> rows;
  final ActiveRestTimer? activeTimer;
  final SessionProgress progress;
}
8. Grid UI Architecture
The grid is important enough to deserve its own shared package/folder:

text
shared/widgets/grid/
  quadrille_grid.dart
  quadrille_grid_row.dart
  set_cell.dart
  grid_column_header.dart
  sticky_exercise_column.dart
  editable_set_cell.dart
Desired behavior
For web/tablet:

sticky exercise column

horizontally scrollable set columns

vertically scrollable exercise rows

compact editing

keyboard navigation

previous session comparison maybe later

For phone:

same underlying data

rendered as exercise cards instead of a full spreadsheet

Use a common view model:

dart
class ExerciseGridRow {
  final SessionExerciseId id;
  final String orderLabel;
  final String exerciseName;
  final RepTarget target;
  final Duration rest;
  final String? notes;
  final List<SetCellViewModel> sets;
}
Then have two renderers:

text
SessionGridWide
SessionGridCompact
9. watchOS Architecture
Key decision
The watch app should not own the full database.

It receives a tiny “active workout snapshot” from the iPhone.

json
{
  "sessionId": "abc",
  "exerciseName": "Barbell Bench Press",
  "orderLabel": "1",
  "setNumber": 3,
  "plannedSets": 4,
  "restEndsAt": "2026-05-31T19:02:30Z",
  "nextExerciseName": "Overhead Press"
}
watchOS modules
text
Watch App
  Views/
    ActiveTimerView.swift
    NoActiveSessionView.swift
    SetControlsView.swift

  Models/
    WatchWorkoutSnapshot.swift
    WatchCommand.swift

  Services/
    WatchConnectivityService.swift
    HapticsService.swift
Communication flow
Flutter starts/restores active session
text
Flutter ActiveSessionController
  → MethodChannel: updateWatchSnapshot
  → iOS native WatchBridge
  → WatchConnectivity
  → watchOS app
Watch sends command
text
watchOS button tap: "+30s"
  → WatchConnectivity
  → iOS WatchBridge
  → EventChannel
  → Flutter TimerController
  → update DB/timer/notification
  → send new snapshot back to watch
Commands
dart
enum WatchCommandType {
  skipRest,
  extendRest,
  shortenRest,
  completeSet,
  pauseTimer,
  resumeTimer,
}
For V1, I would keep this very small:

skipRest

extendRest30

openCurrentExercise

markReady

Do not make the watch app a full set-entry app in V1. Weight/reps entry on watch sounds convenient but will complicate UX and syncing. Add it only after the timer companion works well.

10. Platform Services Layer
Create interfaces in Dart:

dart
abstract interface class NotificationService {
  Future<void> scheduleRestComplete({
    required String id,
    required DateTime endsAt,
    required String title,
    required String body,
  });

  Future<void> cancelRestNotification(String id);
}

abstract interface class HapticsService {
  Future<void> lightImpact();
  Future<void> success();
}

abstract interface class WatchService {
  Future<void> updateSnapshot(WatchWorkoutSnapshot snapshot);
  Stream<WatchCommand> watchCommands();
}
Then implement per platform:

text
notification_service_mobile.dart
notification_service_web.dart
notification_service_stub.dart

watch_service_ios.dart
watch_service_stub.dart

haptics_service_flutter.dart
Use conditional imports where appropriate.

11. Timer and Notification Reliability
This is the most important technical part.

Do not rely on a running Dart timer for truth
Bad model:

dart
remainingSeconds--;
Good model:

dart
final remaining = endsAt.difference(clock.now());
On timer start
persist active timer

schedule local notification

send snapshot to watch

start foreground UI ticker if app is open

dart
Future<void> startTimer(Duration duration) async {
  final now = clock.now();
  final endsAt = now.add(duration);

  await timerRepository.save(
    ActiveRestTimer(
      startedAt: now,
      duration: duration,
      endsAt: endsAt,
    ),
  );

  await notificationService.scheduleRestComplete(
    id: 'active-rest',
    endsAt: endsAt,
    title: 'Rest complete',
    body: 'Time for your next set.',
  );

  await watchService.updateSnapshot(...);
}
On app resume
read active timer

compare endsAt to now

if expired, show “ready” state

clear or preserve timer depending on UX

12. Local-First Sync Strategy
For V1, I would make Quadrille local-only but exportable.

Reason: the app is useful immediately without accounts, auth, cloud, or backend complexity.

However, design IDs and persistence so sync can be added later.

Use UUIDs or ULIDs for all primary IDs:

text
template_01J...
session_01J...
exercise_01J...
set_01J...
Every mutable table should have:

text
created_at
updated_at
deleted_at nullable
sync_status later
V1
local Drift database

manual export/import JSON

maybe iCloud/Google Drive file backup later

V2
Add optional sync.

Possible choices:

Option A: Supabase
Fastest credible sync backend.

Good for:

auth

Postgres

row-level security

simple API

Option B: Custom backend
Given your background, a custom Rust or TypeScript service could be clean.

Good for:

portfolio story

full control

custom sync protocol

But I would not start there.

13. Import / Export Format
Add export early.

It protects you from schema mistakes and makes the app feel trustworthy.

Use a versioned JSON format:

json
{
  "format": "quadrille.export",
  "version": 1,
  "exportedAt": "2026-05-31T19:30:00Z",
  "templates": [],
  "exercises": [],
  "sessions": [],
  "sessionExercises": [],
  "setEntries": []
}
Later this can become the sync payload foundation.

14. Suggested Screens
App shell
text
Today
Templates
History
Exercises
Settings
Today
Primary launch screen.

States:

text
No active workout
  [Start Workout]

Active workout
  Current exercise
  Current set
  Active rest timer
  Session progress
Templates
text
Day 1 Push A
Day 2 Pull A
Day 3 Legs A
Day 4 Push B
Day 5 Pull B
Day 6 Legs B
Day 7 Rest
Template detail
Shows planned grid:

text
Order  Exercise             Sets  Reps    Rest  Notes
1      Barbell bench press  4     6–8     3:00
2A     Overhead press       3     8–10    2:30  bench 8
2B     Lateral raise        3     12–20   1:30
Active session
Phone:

text
[Rest 01:12]

1 Barbell Bench Press
Target: 6–8 reps · 3:00 rest

Set 1  115 × 8
Set 2  120 × 6
Set 3  [weight] [reps] [Save]
Set 4  —
Web/tablet:

Full grid.

History
text
May 31 — Day 1 Push A
May 29 — Day 6 Legs B
May 27 — Day 5 Pull B
Exercise history
text
Barbell Bench Press

Last sessions:
May 31  115×8, 120×6, 120×5
May 24  115×8, 115×6, 110×6

Best estimated 1RM:
...
15. Repository Structure
I’d use a monorepo even if it starts as one app.

text
quadrille/
  README.md
  melos.yaml

  apps/
    quadrille/
      lib/
      ios/
      android/
      web/
      test/
      integration_test/

  packages/
    quadrille_core/
      lib/
        src/
          models/
          value_objects/
          rules/
          ids.dart
      test/

    quadrille_data/
      lib/
        src/
          database/
          daos/
          repositories/
          migrations/
      test/

    quadrille_timer/
      lib/
        src/
          rest_timer_engine.dart
          notification_service.dart
          watch_service.dart
      test/
You can skip melos initially if you want less setup friction, but given your style, a small monorepo is probably worthwhile.

16. Core Package Responsibilities
quadrille_core
Pure Dart. No Flutter imports.

Contains:

IDs

entities

value objects

enums

domain rules

validation

Examples:

dart
RepTarget
Weight
RestDuration
ExerciseOrderLabel
SessionStatus
SetStatus
quadrille_data
Depends on:

quadrille_core

Drift

Contains:

database schema

DAOs

repository implementations

migrations

quadrille_timer
Mostly pure Dart plus abstract platform interfaces.

Contains:

active timer state machine

deadline calculations

timer snapshots

notification/watch interfaces

The Flutter app wires it to actual platform services.

17. Domain Details Worth Modeling Early
Your sheets imply more than simple exercise / weight / reps.

I would include these concepts early, even if the UI starts simple.

Order labels
You use labels like:

text
1
2A
2B
3A
3B
4A
4B
5
So do not store only integer order.

Use:

dart
class ExerciseOrder {
  final int groupNumber; // 2
  final String? variant; // A
  final int sortIndex;
  final String label; // "2A"
}
Rep target
Supports:

text
6–8
8–12
12–20
15–25
30–60s
So model:

dart
sealed class Target {
  RepRange
  DurationRange
  RepsAndDuration
}
For V1, simpler:

dart
class RepTarget {
  final int? minReps;
  final int? maxReps;
  final Duration? minDuration;
  final Duration? maxDuration;
}
Rest duration
Your sheets include:

text
90s
2'
2.5'
3'
60s
Normalize internally to seconds.

Display however you prefer.

Bodyweight
Some entries use bodyweight or “b”.

Do not force every set to have a numeric weight.

Use:

dart
enum LoadKind {
  externalWeight,
  bodyweight,
  assistedBodyweight,
  machineSetting,
  timeOnly,
  none,
}
Again, V1 can simplify, but the model should not assume barbell-only.

18. Testing Plan
Unit tests
Test pure domain logic:

rep target validation

rest duration parsing

set completion rules

session progress calculation

timer remaining calculation

timer expiration

Repository tests
Use in-memory Drift database.

Test:

create template

start session from template

edit template does not mutate past session

save set

complete session

export/import round trip

Widget tests
Focus on:

active set entry

timer display

grid cell editing

template exercise editing

Integration tests
One happy path:

text
Create template
Start session
Enter first set
Rest timer starts
Skip rest
Enter second set
Complete session
View in history
19. Build Phases
Phase 0 — Project foundation
Create Flutter app

Set up Riverpod

Set up Drift

Set up routing

Create app theme

Add core models

Add first migrations

Deliverable:

text
App launches on web, iOS simulator, Android emulator.
Database works.
Phase 1 — Templates
Exercise library

Create/edit templates

Add template exercises

Configure sets/reps/rest/notes

Seed your six lifting days plus rest day

Deliverable:

text
You can recreate your paper sheets in Quadrille.
Phase 2 — Active workout logging
Start session from template

Copy template rows into session rows

Display active session

Log weight/reps per set

Session history

Complete session

Deliverable:

text
You can leave the paper at home.
Phase 3 — Rest timers
Auto-start rest timer after set

Timer banner / full-screen timer

Local notifications

Haptics

Extend/skip/cancel timer

App lifecycle restore

Deliverable:

text
You no longer need custom watch timers.
Phase 4 — watchOS companion
Add native watch target

Implement WatchConnectivity bridge

Send active timer snapshot

Show countdown

Haptic when rest ends

Add +30s / skip rest controls

Deliverable:

text
Your wrist tells you when to lift again.
Phase 5 — Polish and export
JSON export/import

Better history

Previous-session suggestions

PR indicators

Keyboard support on web

App icon / landing page at quadrille.app

Deliverable:

text
Quadrille feels like a real product.
20. MVP Cut Line
For a clean V1, I would not build:

accounts

cloud sync

social features

public workout programs

AI recommendations

full analytics dashboard

plate calculator

camera/video

complex exercise taxonomy

full watch set-entry

Apple Health / Google Fit integration

The MVP should be:

text
Templates
→ Start session
→ Log sets in a grid/card UI
→ Auto rest timer
→ Session history
→ Local persistence
→ Basic watch timer companion
That is already a substantial, polished app.

21. Recommended Initial Package List
text
dependencies:
  flutter:
    sdk: flutter

  flutter_riverpod: ^3.0.0
  go_router: ^16.0.0

  drift: ^2.0.0
  sqlite3_flutter_libs: ^0.5.0
  path_provider: ^2.0.0
  path: ^1.9.0

  freezed_annotation: ^3.0.0
  json_annotation: ^4.9.0

  uuid: ^4.0.0
  intl: ^0.20.0
  collection: ^1.19.0

  flutter_local_notifications: ^19.0.0
  timezone: ^0.10.0

dev_dependencies:
  build_runner: ^2.0.0
  drift_dev: ^2.0.0
  freezed: ^3.0.0
  json_serializable: ^6.0.0
  mocktail: ^1.0.0
  flutter_test:
    sdk: flutter
Version numbers will need checking at implementation time, but this is the shape.

22. App Identity / Naming Integration
Because Quadrille comes from graph paper, I would lean into the visual identity:

subtle grid-paper background

square cell motifs

clean thin-line dividers

blue-gray graph-paper accent

“today’s sheet” metaphor

session grid as the hero UI

Potential tagline:

Quadrille — lifting logs on the grid.

Or:

Quadrille — templates, sets, and rest timers for serious training.

Or:

Quadrille — the workout sheet that times your rest.

The last one is probably the clearest.

23. Final Architecture Summary
Quadrille should be built as:

text
Flutter app for web/iOS/Android
  Riverpod state management
  Drift local database
  template/session/set domain model
  deadline-based rest timer engine
  local notifications
  responsive grid/card UI

Native SwiftUI watchOS companion
  receives active timer snapshot
  shows countdown
  provides haptics and simple controls
  communicates through WatchConnectivity

Local-first persistence
  export/import in V1
  optional sync in V2
The core technical bet should be:

Everything revolves around a session grid and a deadline-based rest timer.

If you get those two abstractions right, the rest of the app — templates, history, watch companion, analytics, export, sync — can grow naturally without fighting the architecture.

# Claude Opus 4.8 Thinking

I now have everything I need. Here's the complete architecture plan.

Quadrille — Architecture Plan
A cross-platform Dart/Flutter weightlifting tracker for web, iOS, watchOS, and Android. This plan covers the high-level architecture, the data model, the hard problems (rest timers, watchOS, sync), the package stack, and a phased build path.

1. Guiding Principles
Local-first, offline-always. The gym has bad signal. The local database is the source of truth; the cloud is a sync target, not a dependency. This is non-negotiable for a gym-floor app.

Wall-clock timers, not tick-counting. Never count down by decrementing a counter each second — store an absolute endsAt timestamp and compute remaining time from DateTime.now(). This survives app backgrounding, screen-off, and process death.

Shared Dart core, native edges. Flutter handles ~95% of the app (all four targets). The watchOS complication/standalone surface and the OS-level alarm/notification scheduling are the native boundaries you deliberately accept.

MVVM + repository pattern, the officially recommended Flutter architecture: View → ViewModel → Repository → Service, dependencies pointing inward.

2. Layered Architecture
Flutter's official guidance is to split into a UI layer (Views + ViewModels) and a Data layer (Repositories + Services), with separation of concerns as the top principle.
 Combined with the 2026-standard feature-first folder organization:

text
lib/
├── core/                      # depends on nothing in features/
│   ├── di/                    # Riverpod providers / DI wiring
│   ├── database/              # Drift database (conditional web/native import)
│   ├── timer/                 # wall-clock RestTimerService
│   ├── notifications/         # flutter_local_notifications wrapper
│   ├── watch/                 # watch_connectivity bridge
│   ├── sync/                  # PowerSync / sync engine wiring
│   ├── theme/  utils/  constants.dart
│
├── features/
│   ├── templates/             # workout templates (Push A, Pull B, …)
│   │   ├── presentation/      # screens, widgets, view_models
│   │   ├── domain/            # entities, repository interfaces
│   │   └── data/              # models (DTOs), repository impls, services
│   ├── session/               # the live "fill in the grid" workout
│   ├── timer/                 # rest-timer UI (ring countdown)
│   ├── history/               # past sessions, read-only at first
│   └── exercises/             # exercise library / catalog
│
└── shared/                    # reusable widgets (grid cell, set row)
Layer responsibilities:

Layer	Role	Holds state?
View (widgets)	Render UI, forward user events. No logic beyond show/hide and layout.
No
ViewModel	Filtering/sorting/transform, UI state, commands the view calls.
Yes (UI state)
Repository	Single source of truth per data type; caching, error handling, sync orchestration.
No (delegates)
Service	Wraps one data source (Drift DB, notification plugin, watch channel). Returns Future/Stream, holds no state.
No
This is the structure Flutter's own docs prescribe, so it also makes the project a clean portfolio artifact.

3. State Management: Riverpod
Recommendation: Riverpod 3.x. For new 2026 Flutter projects it is the consensus default — async-first, compile-time-safe, lowest boilerplate, and it doubles as your dependency-injection mechanism so you never need get_it or singletons.
 BLoC is the alternative, but its event/state ceremony is aimed at large regulated teams and is overkill for a solo-built personal tool.

Riverpod also gives you per-screen provider scoping and easy test overrides (fakes), which Flutter's testing guidance specifically recommends.
 Use AsyncNotifier/Notifier providers for ViewModels and provider overrides to inject fake repositories in tests.

4. Data Model (v1 schema)
This maps your paper sheets directly. The grid columns (multiple dated weight/rep entries per exercise on one sheet) become separate sessions referencing a shared template.

text
ExerciseDef            # the catalog entry (reusable across templates)
  id, name, category, defaultRestSeconds, notes, isUnilateral

WorkoutTemplate        # "Day 1: Push A", "Day 6: Legs B"
  id, name, dayLabel, orderIndex

TemplateExercise       # ordered row in a template (the left column of your sheet)
  id, templateId, exerciseDefId, orderIndex (e.g. "2A","2B" supersets),
  targetSets, repRangeLow, repRangeHigh, restSeconds, notes
  supersetGroup        # "2A"/"2B" share a group → drives superset UI

WorkoutSession         # one dated workout = one column on your sheet
  id, templateId, startedAt, endedAt, lockerStart, lockerEnd, notes

LoggedSet              # one cell: weight × reps for set N
  id, sessionId, templateExerciseId, setIndex,
  weight, reps, isWarmup, isFailure, painFlag (your "P=pain" / "b"=bodyweight),
  restActualSeconds, completedAt

UserSettings
  id, units (lb/kg), barWeight (your "20kg bar = ? lbs" TODO),
  defaultRestSeconds, watchHapticsEnabled
Notes tied to your sheets:

Your 2A/2B, 3A/3B notation = supersets → modeled via supersetGroup, so the UI can interleave them and rest only after the pair.

Your annotations (P=pain, b=bodyweight, <=easy, R10/L10 for unilateral) → flags on LoggedSet plus isUnilateral on ExerciseDef.

The "start the session pre-filled from a template" requirement (no recopying) is just: clone TemplateExercise rows into an empty grid of LoggedSet placeholders.

5. Persistence: Drift (SQLite)
Use Drift (the typed SQLite layer) as the local store across all platforms.

Native (iOS/Android): Drift over sqlite3 via FFI.

Web: Drift compiles to web via sqlite3.wasm + a web worker; you must serve the wasm asset and use conditional imports (connection.dart exporting native.dart vs web.dart) so dart:ffi never reaches the web build.
 This is a known, documented gotcha — budget a half-day for it.

Wrap Drift behind your repository interfaces so the UI never touches SQL directly — this is the abstraction that later lets you add cloud sync without touching a single widget.

6. The Rest Timer (the hard, signature problem)
This is what justifies the app over paper, and it has three distinct sub-problems.

6a. Timer correctness — wall-clock, not ticks
Store an absolute endsAt = DateTime.now().add(restSeconds) when a set is logged. The UI ticks every ~250ms only to redraw, but always recomputes remaining = endsAt - now. If the app is backgrounded/killed and reopened, the countdown is instantly correct because it's derived from the timestamp, not an in-memory counter.
 Listen to AppLifecycleState to reconcile on resume.

6b. Firing when the phone is in your pocket (app backgrounded/closed)
Do not rely on background Dart execution — it's unreliable on both platforms.
 Instead, schedule an OS-level local notification at endsAt the moment the rest starts, using flutter_local_notifications with zonedSchedule + tz.TZDateTime.

Android: Requires POST_NOTIFICATIONS (Android 13+) and, for to-the-second accuracy, exact alarms — set androidScheduleMode: AndroidScheduleMode.alarmClock (or exactAllowWhileIdle) and declare SCHEDULE_EXACT_ALARM/USE_EXACT_ALARM in the manifest, requesting the permission at runtime.
 Reschedule on device reboot.

iOS: Notification sounds/haptics don't fire from the foreground timer when backgrounded — the scheduled local notification is what buzzes you.

Pattern: when the timer starts, both (1) run the in-app visual countdown and (2) schedule a backup local notification; cancel the notification if the user manually ends rest early.

6c. Glanceable UI
A large CustomPaint ring with the seconds remaining ("43s left") — this is squarely Flutter's animation/custom-paint strength, and it's the same widget shared across phone and web.

7. watchOS — the deliberate native edge
This is the one place the "one Flutter codebase" model breaks, and that's expected. Flutter does not run a UI on watchOS / Apple Watch — you build the watch surface natively in SwiftUI, and bridge it to your Flutter iOS app.

Architecture:

Watch app in SwiftUI (separate watchOS target in the Xcode project, alongside the Flutter-generated iOS Runner).

Bridge via watch_connectivity package on the Flutter side ↔ WatchConnectivity (WCSession) on the native side, to send the current set context to the watch and receive "rest done / log set" events back.

MethodChannel ferries connectivity events between the native iOS layer and Flutter.

Scoping advice: Treat watchOS as v3, not v1. The Xcode multi-target setup is fiddly (target/Info.plist build-phase quirks are a documented pain point).
 For v1, the scheduled local notification already buzzes your wrist if you wear an Apple Watch paired to the phone — you get 80% of the value with 0% of the native watch work. Build the dedicated watch app only once the phone app is solid.

For Android, the equivalent (Wear OS) is similarly a native edge — defer it the same way. Flutter's watch story being weak here is itself the instructive lesson: identical-codebase frameworks stop at the wrist.

8. Cloud Sync (v2 — keep out of v1)
v1 is local-only, no accounts (your stated scope). When you want multi-device sync (phone → web), the clean local-first options are:

Option	Fit
PowerSync + Supabase	Best fit. Purpose-built local-first sync over Drift/SQLite; now has Flutter web support (beta) via the same sqlite3.wasm/worker assets you already need for Drift.
 Pairs with Riverpod + Drift as a documented stack.
Brick + Supabase	All-in-one offline-first data manager over SQLite; simpler but less flexible.
Supabase + custom Drift sync	More control, more work.
Because the repository layer hides the data source, adding PowerSync later is a data-layer change that doesn't touch ViewModels or widgets.
 Use UUIDs for primary keys from day one so local rows merge cleanly when sync arrives.

9. Web specifics
Flutter Web "remains Flutter" — same MVVM/widget model; the web build mainly changes shipping, not architecture.

Consider the WasmGC build for performance, but note it requires WasmGC-capable browsers — keep the JS build as fallback.

The grid UI translates well to a desktop-width web layout (more columns visible), making web a natural "review history at home" surface complementing the phone's "log on the floor" role.

10. Recommended Package Stack
Concern	Package
State mgmt + DI	flutter_riverpod (3.x)
Local DB	drift + sqlite3 (+ sqlite3_flutter_libs, sqlite3.wasm for web)
Notifications/alarms	flutter_local_notifications + timezone
Navigation	go_router (Flutter-recommended)
Watch bridge (iOS)	watch_connectivity
Cloud sync (v2)	powersync + supabase_flutter
IDs	uuid
Errors	fpdart (Either<Failure, Success>) for explicit error handling
11. Phased Build Path
v1 — Local single-device (the daily driver):

Drift schema + repositories (test the web conditional-import early).

Templates feature: create/edit "Push A", "Pull B" with ordered exercises, rest intervals, superset groups.

Session feature: "Start from template" → pre-filled grid; tappable weight/reps cells, auto-advance.

Rest timer: wall-clock ring + scheduled local-notification backup with exact-alarm handling.

History: read-only past sessions.

v2 — Multi-device:

Supabase auth + PowerSync; web build polished as the "review" surface.

v3 — Wrist:

SwiftUI watchOS target + watch_connectivity bridge for at-a-glance rest + quick set logging.

The clean stack narrative holds
Flutter owns the correctness-tolerant, UI-and-timer-heavy, consistency-friendly core (templates, grid, history, countdown) across all four targets; native owns the deliberate edges — the OS alarm scheduler and the watchOS surface. That boundary is exactly where it should be for this app, and building it teaches you the Flutter↔native bridge on a low-stakes, genuinely-useful tool.

Want me to draft the concrete Drift table definitions (Dart code) and the Riverpod provider graph for the session/timer features next?

# Gemini 3.1 Pro Thinking

Here is a comprehensive architecture plan for Quadrille.

Since you have a strong engineering background (Rust, React, full-stack), this plan skips the beginner tutorials and focuses directly on the system design, the platform boundaries, the data schema required to replicate your paper grids, and the exact strategy needed to handle the cross-platform constraints (especially watchOS and background timers).

1. The Tech Stack Selection
For a clean, offline-first, state-heavy application across Android, iOS, and Web, here is the recommended stack:

Framework: Flutter / Dart

State Management: Riverpod (flutter_riverpod). It is the modern standard for Flutter, offering compile-time safety and excellent dependency injection for tying local DB streams to UI state.

Routing: GoRouter. Handles deep linking naturally (crucial for the Web build).

Local Persistence: Drift (formerly Moor). A reactive, type-safe SQLite wrapper for Dart.

Cross-platform note: Drift works natively on iOS/Android and has WebAssembly (Wasm) SQLite support for the web target, meaning your persistence layer remains identical across all three screens.

Notifications/Haptics: flutter_local_notifications and vibration.

2. The Data Model (SQLite / Drift Schema)
Based on the 7 paper sheets you shared (e.g., "Day 1: Push A", "Day 3: Legs A (Quad & Glute)", exercises with specific rest times like 2.5', 90s, 3'), your schema needs to separate Templates from Logged Sessions.

Here is the relational shape to implement in Drift:

Templates (The Planning Layer)

WorkoutTemplates: id, name (e.g., "Pull A"), notes

TemplateExercises: id, template_id, name (e.g., "Barbell Row"), order_index (1, 2A, 2B), target_sets, rep_range (e.g., "6-10"), rest_seconds (e.g., 180).

Sessions (The Logging Layer)

Sessions: id, template_id, start_time, end_time, notes (e.g., "locker start 10:45a")

LoggedSets: id, session_id, exercise_name, set_number, weight_lbs, reps, completion_time, is_warmup (boolean).

Why this shape? By copying exercise_name to the LoggedSets table rather than strictly foreign-keying to TemplateExercises, you ensure that if you delete or rename a template exercise later, your historical workout data doesn't break.

3. The Timer & Background Strategy (The Hard Part)
The biggest technical trap in fitness apps is trying to run a literal Timer.periodic isolate in the background. iOS and Android will aggressively kill background isolates to save battery.

The "Stateless" Timer Architecture:

On Log Set: User taps the cell to log "135 lbs x 10 reps".

Calculate: App reads the exercise's rest_seconds (e.g., 90s) and calculates targetTime = DateTime.now().add(90 seconds).

Schedule Notification: App passes targetTime to flutter_local_notifications to schedule an OS-level local notification ("Rest complete! Next: Overhead Press").

UI Animation: If the app remains in the foreground, a Riverpod provider reads targetTime - DateTime.now() and drives a Ticker (via a Flutter AnimationController) to animate your "Glanceable countdown ring".

Lifecycle handling: If the user minimizes the app, the UI ticking stops. The OS handles the scheduled notification. When the app is foregrounded again, the UI recalculates remaining time from targetTime and resumes the animation perfectly in sync.

Web Fallback: For the web target, flutter_local_notifications relies on the browser's Notification API. You will need to request notification permissions on the web explicitly.

4. The watchOS Architecture (The Native Boundary)
Crucial reality check: Flutter does not compile to watchOS. There is no flutter build watchos.

To get rest timers to buzz your wrist natively, you must step out of Dart and build a Swift companion app. This perfectly fulfills your desire to learn the native-bridge boundary.

The Architecture:

iOS Side: Your Flutter app uses the flutter_wear_os_connectivity package (or pigeon/custom platform channels) to wrap Apple's WCSession (Watch Connectivity Session).

watchOS Side: You build a lightweight, native SwiftUI target inside Xcode.

The Message Pass: When a set is logged in Flutter, the Dart code invokes a platform channel: methodChannel.invokeMethod('startWatchTimer', {'duration': 90}).

The Wrist Buzz: The SwiftUI app receives this, runs a native watchOS timer, and uses WKInterfaceDevice.current().play(.notification) to trigger the haptic tap on the wrist.

For Android/Wear OS: The same concept applies, using a small native Kotlin/Jetpack Compose Wear OS app and the Android Wearable Data Layer API.

5. Project Directory Structure (Feature-First)
Because you're coming from enterprise architectures, avoid organizing by type (e.g., all models in one folder, all UI in another). Group by feature:

text
lib/
 ├── main.dart
 ├── core/                  # App-wide infrastructure
 │    ├── database/         # Drift configuration & tables
 │    ├── theme/            # Quadrille's visual identity, typography, colors
 │    ├── notifications/    # Local notification service wrappers
 │    └── router/           # GoRouter configuration
 ├── features/              # Feature bounded contexts
 │    ├── templates/        # Building/editing workout routines
 │    │    ├── domain/      # Models
 │    │    ├── data/        # Repositories (Drift queries)
 │    │    └── presentation/# UI (Template editor)
 │    ├── session/          # Active workout logging (The Grid)
 │    │    ├── application/ # Timer logic, Riverpod providers
 │    │    └── presentation/# UI (Grid UI, Timer Ring, active inputs)
 │    └── history/          # Viewing past workouts
6. Suggested Development Roadmap
To keep scope creep strictly managed, I recommend this path:

Phase 1: The Core UI (Stateless Grid). Build the UI for the paper sheets using dummy data. Get the spreadsheet-like data entry feeling right. Focus on keyboard types (number pads) and auto-advancing focus nodes so logging a set takes less than a second.

Phase 2: Persistence (Drift). Implement the SQLite database. Create a basic "Start Workout" flow that reads a template and instantiates an empty grid.

Phase 3: The Timer State. Implement the targetTime logic and the Riverpod timer provider. Get the on-screen UI ring working seamlessly.

Phase 4: OS Notifications. Bind flutter_local_notifications to the timer start. Test backgrounding the app and receiving the alert. (This gives you a fully functional MVP).

Phase 5: The watchOS Stretch Goal. Open Xcode, add the Watch target, and write the Swift WCSession listener.

This architecture leverages Flutter exactly for what it's best at (complex, stateful UI grids deployed cross-platform) while cleanly mapping out the platform-specific bridges (notifications and watches) you'll need to cross.