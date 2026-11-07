import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/core/database/database.dart';
import 'package:quadrille/core/providers.dart';
import 'package:quadrille/features/equipment/equipment_providers.dart';

void main() {
  late QuadrilleDatabase db;
  late ProviderContainer container;
  final provider = equipmentBusyControllerProvider('Bench');

  setUp(() {
    db = QuadrilleDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    container.listen(provider, (_, _) {});
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('save result can undo its report within the invoking profile', () async {
    final result = await container.read(provider.notifier).record();
    expect(result.saved, isTrue);
    expect(result.isCurrent, isTrue);
    expect(await result.undo(), isTrue);
    final history = await container
        .read(equipmentBusyRepositoryProvider)
        .watchHistory('Bench')
        .first;
    expect(history.reports, isEmpty);
  });

  test(
    'save result cannot undo after the profile changes, even on return',
    () async {
      final result = await container.read(provider.notifier).record();
      final repository = container.read(equipmentBusyRepositoryProvider);

      container.read(currentProfileProvider.notifier).set('another-profile');
      container.read(provider);
      expect(result.isCurrent, isFalse);
      expect(await result.undo(), isFalse);

      container.read(currentProfileProvider.notifier).set(localProfileName);
      container.read(provider);
      expect(result.isCurrent, isFalse);
      expect(await result.undo(), isFalse);
      expect(
        (await repository.watchHistory('Bench').first).reports,
        hasLength(1),
      );
    },
  );
}
