import 'package:uuid/uuid.dart';

/// Identifier generation for all entities.
///
/// IDs are UUID v4 strings generated client-side. Generating them locally
/// (rather than relying on an auto-increment column) means rows created
/// offline can merge cleanly once cloud sync arrives in v2 — no ID collisions,
/// no server round-trip required to create a record.
const _uuid = Uuid();

/// Generates a new unique identifier for a freshly created entity.
String newId() => _uuid.v4();
