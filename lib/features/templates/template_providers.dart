import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database.dart';
import '../../core/providers.dart';
import 'data/template_repository.dart';

final templateRepositoryProvider = Provider<TemplateRepository>((ref) {
  return TemplateRepository(ref.watch(databaseProvider));
});

/// All templates for the list screen.
final templatesProvider = StreamProvider<List<WorkoutTemplate>>((ref) {
  return ref.watch(templateRepositoryProvider).watchTemplates();
});

/// A single template by id (for the detail/editor screen).
final templateProvider =
    StreamProvider.family<WorkoutTemplate?, String>((ref, id) {
  return ref.watch(templateRepositoryProvider).watchTemplate(id);
});

/// The ordered exercise rows of a template.
final templateExercisesProvider =
    StreamProvider.family<List<TemplateExercise>, String>((ref, templateId) {
  return ref.watch(templateRepositoryProvider).watchExercises(templateId);
});
