import 'package:drift/drift.dart';

import '../domain/enums.dart';

/// Drift table definitions for Quadrille.
///
/// Conventions:
/// * Every table uses a client-generated UUID text primary key (see
///   `newId()`), so rows created offline merge cleanly when sync arrives.
/// * Every mutable table carries `createdAt`/`updatedAt`; soft-delete via
///   `archived` where history must be preserved.
/// * Enums are stored by name (`textEnum`) so adding/reordering values can't
///   corrupt existing rows.
/// * Rest intervals are stored as whole seconds; rep/duration targets as four
///   nullable integer columns mirroring [RepTarget].

/// Canonical exercise catalog, reusable across templates.
class Exercises extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get category =>
      textEnum<ExerciseCategory>().withDefault(Constant(ExerciseCategory.other.name))();
  IntColumn get defaultRestSeconds => integer().withDefault(const Constant(120))();
  TextColumn get loadKind =>
      textEnum<LoadKind>().withDefault(Constant(LoadKind.externalWeight.name))();
  BoolColumn get isUnilateral => boolean().withDefault(const Constant(false))();
  TextColumn get notes => text().nullable()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  // Soft-delete tombstone: set (not row-removed) so deletions propagate on sync.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// A reusable workout plan — one paper sheet, e.g. "Day 1 Push A".
class WorkoutTemplates extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get dayLabel => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  // Soft-delete tombstone: set (not row-removed) so deletions propagate on sync.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// One row in a template — the left column of a sheet (an exercise plus its
/// planned sets/reps/rest/notes and superset grouping).
class TemplateExercises extends Table {
  TextColumn get id => text()();
  TextColumn get templateId =>
      text().references(WorkoutTemplates, #id, onDelete: KeyAction.cascade)();
  TextColumn get exerciseId =>
      text().nullable().references(Exercises, #id, onDelete: KeyAction.setNull)();
  TextColumn get displayName => text()();
  TextColumn get orderLabel => text()();
  IntColumn get sortIndex => integer()();
  TextColumn get supersetGroup => text().nullable()();
  IntColumn get targetSets => integer().withDefault(const Constant(3))();
  IntColumn get repMin => integer().nullable()();
  IntColumn get repMax => integer().nullable()();
  IntColumn get durationMinSeconds => integer().nullable()();
  IntColumn get durationMaxSeconds => integer().nullable()();
  IntColumn get restSeconds => integer().withDefault(const Constant(120))();
  TextColumn get notes => text().nullable()();
  BoolColumn get isUnilateral => boolean().withDefault(const Constant(false))();
  TextColumn get loadKind =>
      textEnum<LoadKind>().withDefault(Constant(LoadKind.externalWeight.name))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  // Soft-delete tombstone: set (not row-removed) so deletions propagate on sync.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// One performed workout on a date — a single dated column on the sheet.
class WorkoutSessions extends Table {
  TextColumn get id => text()();
  TextColumn get templateId =>
      text().nullable().references(WorkoutTemplates, #id, onDelete: KeyAction.setNull)();
  TextColumn get name => text()();
  TextColumn get status =>
      textEnum<SessionStatus>().withDefault(Constant(SessionStatus.active.name))();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  TextColumn get generalNotes => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  // Soft-delete tombstone: set (not row-removed) so deletions propagate on sync.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// A snapshot of a template row at the moment the session started. Copied (not
/// foreign-keyed) so later template edits never mutate recorded history.
class SessionExercises extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId =>
      text().references(WorkoutSessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get sourceTemplateExerciseId => text().nullable()();
  TextColumn get displayName => text()();
  TextColumn get orderLabel => text()();
  IntColumn get sortIndex => integer()();
  TextColumn get supersetGroup => text().nullable()();
  IntColumn get plannedSets => integer().withDefault(const Constant(3))();
  IntColumn get repMin => integer().nullable()();
  IntColumn get repMax => integer().nullable()();
  IntColumn get durationMinSeconds => integer().nullable()();
  IntColumn get durationMaxSeconds => integer().nullable()();
  IntColumn get plannedRestSeconds => integer().withDefault(const Constant(120))();
  TextColumn get plannedNotes => text().nullable()();
  TextColumn get sessionNotes => text().nullable()();
  BoolColumn get isUnilateral => boolean().withDefault(const Constant(false))();
  TextColumn get loadKind =>
      textEnum<LoadKind>().withDefault(Constant(LoadKind.externalWeight.name))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  // Soft-delete tombstone: set (not row-removed) so deletions propagate on sync.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// One logged cell: weight × reps (or duration/bodyweight) for set N.
class SetEntries extends Table {
  TextColumn get id => text()();
  TextColumn get sessionExerciseId =>
      text().references(SessionExercises, #id, onDelete: KeyAction.cascade)();
  IntColumn get setNumber => integer()();
  RealColumn get weight => real().nullable()();
  TextColumn get weightUnit =>
      textEnum<WeightUnit>().withDefault(Constant(WeightUnit.lb.name))();
  IntColumn get reps => integer().nullable()();
  IntColumn get leftReps => integer().nullable()();
  IntColumn get rightReps => integer().nullable()();
  TextColumn get status =>
      textEnum<SetStatus>().withDefault(Constant(SetStatus.pending.name))();
  RealColumn get rpe => real().nullable()();
  TextColumn get pain => textEnum<PainLevel>().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  // Soft-delete tombstone: set (not row-removed) so deletions propagate on sync.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The single active rest timer, modelled as a wall-clock deadline ([endsAt])
/// rather than a tick counter — so the countdown is always recomputed from
/// `endsAt - now` and survives backgrounding, screen-off, reload, and process
/// death. At most one row (id is always `'singleton'`); absent when no timer.
class ActiveTimers extends Table {
  @override
  String get tableName => 'active_timers';

  TextColumn get id => text().withDefault(const Constant('singleton'))();
  TextColumn get sessionId => text().nullable()();
  TextColumn get sessionExerciseId => text().nullable()();

  /// Exercise label, denormalized for the countdown UI and notification body.
  TextColumn get label => text().nullable()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endsAt => dateTime()();
  IntColumn get durationSeconds => integer()();
  TextColumn get status =>
      textEnum<TimerStatus>().withDefault(Constant(TimerStatus.running.name))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Single-row application settings (id is always `'singleton'`).
class AppSettingsTable extends Table {
  @override
  String get tableName => 'app_settings';

  TextColumn get id => text().withDefault(const Constant('singleton'))();
  TextColumn get units =>
      textEnum<WeightUnit>().withDefault(Constant(WeightUnit.lb.name))();
  IntColumn get defaultRestSeconds => integer().withDefault(const Constant(120))();
  BoolColumn get autoStartTimer => boolean().withDefault(const Constant(true))();
  BoolColumn get keepScreenAwake => boolean().withDefault(const Constant(true))();
  BoolColumn get watchHapticsEnabled => boolean().withDefault(const Constant(true))();

  // Cloud sync (v2). Endpoint defaults to the hosted same-origin API; the
  // token is set by the user. Sync is off until a token is present.
  TextColumn get syncEndpoint =>
      text().withDefault(const Constant('https://quadrille.app/api'))();
  TextColumn get syncToken => text().nullable()();

  // Auto-sync bookkeeping (v4): push on finish / pull on launch, plus the last
  // synced revision + time so a pull never clobbers unsynced local changes.
  BoolColumn get autoSync => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastSyncAt => dateTime().nullable()();
  IntColumn get lastSyncedRevision => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
