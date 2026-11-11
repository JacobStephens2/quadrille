import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quadrille/core/domain/enums.dart';
import 'package:quadrille/features/session/session_starting.dart';
import 'package:quadrille/features/templates/data/template_repository.dart';
import 'package:quadrille/features/templates/presentation/template_detail_screen.dart';
import 'package:quadrille/features/today/presentation/today_screen.dart';

import 'session_starting_fixture.dart';

void main() {
  late StartingFixture fixture;
  late GoRouter router;

  setUp(() async {
    fixture = StartingFixture();
    await fixture.open();
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (_, _) => const NoTransitionPage(child: TodayScreen()),
        ),
        GoRoute(
          path: '/templates',
          pageBuilder: (_, _) =>
              const NoTransitionPage(child: Scaffold(body: Text('Away'))),
        ),
        GoRoute(
          path: '/detail',
          pageBuilder: (_, _) => const NoTransitionPage(
            child: TemplateDetailScreen(templateId: StartingFixture.templateId),
          ),
        ),
        GoRoute(
          path: '/session/:id',
          pageBuilder: (_, state) => NoTransitionPage(
            child: Scaffold(
              body: Text('Workout ${state.pathParameters['id']}'),
            ),
          ),
        ),
      ],
    );
  });
  tearDown(() async {
    router.dispose();
    await fixture.close();
  });

  Future<void> show(WidgetTester tester, String entry) async {
    router.go(entry);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await drain(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  Finder control(String entry) => entry == '/'
      ? find.widgetWithText(ListTile, 'Push A')
      : find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Start workout',
        );

  bool enabled(WidgetTester tester, String entry) => entry == '/'
      ? tester.widget<ListTile>(control(entry)).onTap != null
      : tester.widget<IconButton>(control(entry)).onPressed != null;

  for (final entry in ['/', '/detail']) {
    testWidgets('$entry shows pending and accepts duplicate taps only once', (
      tester,
    ) async {
      await show(tester, entry);
      final gate = StartingWait();
      fixture.aRepository.waiting = gate;
      await tester.tap(control(entry));
      await tester.tap(control(entry));
      await tester.pump();
      await tester.runAsync(() => gate.entered.future);
      expect(fixture.aRepository.submissions, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(enabled(tester, entry), isFalse);
      gate.completion.complete();
      await drain(tester);
      final saved = await tester.runAsync(
        () => fixture.aRepository.watchActiveSession().first,
      );
      expect(find.text('Workout ${saved!.id}'), findsOneWidget);
      expect(
        router.routeInformationProvider.value.uri.path,
        '/session/${saved.id}',
      );
    });

    testWidgets('$entry reports failure and enables retry', (tester) async {
      await show(tester, entry);
      fixture.aRepository.fail = true;
      await tester.tap(control(entry));
      await drain(tester);
      expect(
        find.text('Could not start this workout. Please try again.'),
        findsOneWidget,
      );
      expect(enabled(tester, entry), isTrue);
      expect(tester.takeException(), isNull);
      fixture.aRepository.fail = false;
      await tester.tap(control(entry));
      await drain(tester);
      final saved = await tester.runAsync(
        () => fixture.aRepository.watchActiveSession().first,
      );
      expect(find.text('Workout ${saved!.id}'), findsOneWidget);
    });

    for (final fails in [false, true]) {
      testWidgets(
        '$entry suppresses stale ${fails ? 'error' : 'navigation'} after a profile switch',
        (tester) async {
          await show(tester, entry);
          final gate = StartingWait();
          fixture.aRepository.waiting = gate;
          fixture.aRepository.fail = fails;
          await tester.tap(control(entry));
          await tester.runAsync(() => gate.entered.future);
          fixture.switchTo('b');
          await drain(tester);
          expect(enabled(tester, entry), isTrue);
          gate.completion.complete();
          await drain(tester);
          expect(router.routeInformationProvider.value.uri.path, entry);
          expect(find.textContaining('Please try again'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            expect(
              await fixture.aRepository.watchActiveSession().first,
              fails ? isNull : isNotNull,
            );
            expect(
              await fixture.bRepository.watchActiveSession().first,
              isNull,
            );
          });
        },
      );

      testWidgets(
        '$entry removal retains accepted persistence without stale feedback (${fails ? 'failure' : 'success'})',
        (tester) async {
          await show(tester, entry);
          final gate = StartingWait();
          fixture.aRepository.waiting = gate;
          fixture.aRepository.fail = fails;
          final handle = fixture.container.read(
            sessionStartingProvider(StartingFixture.templateId),
          );
          await tester.tap(control(entry));
          await tester.runAsync(() => gate.entered.future);
          router.go('/templates');
          await drain(tester);
          expect(find.byType(TodayScreen), findsNothing);
          expect(find.byType(TemplateDetailScreen), findsNothing);
          gate.completion.complete();
          await drain(tester);
          expect(handle.isPending, isFalse);
          expect(find.text('Away'), findsOneWidget);
          expect(find.textContaining('Please try again'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            expect(
              await fixture.aRepository.watchActiveSession().first,
              fails ? isNull : isNotNull,
            );
          });
        },
      );
    }

    testWidgets(
      '$entry remount observes retained pending state and releases it on failure',
      (tester) async {
        await show(tester, entry);
        final gate = StartingWait();
        fixture.aRepository.waiting = gate;
        fixture.aRepository.fail = true;
        await tester.tap(control(entry));
        await tester.runAsync(() => gate.entered.future);
        router.go('/templates');
        await drain(tester);
        router.go(entry);
        await drain(tester);
        expect(enabled(tester, entry), isFalse);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        gate.completion.complete();
        await drain(tester);
        expect(enabled(tester, entry), isTrue);
        fixture.aRepository.fail = false;
        await tester.tap(control(entry));
        await drain(tester);
        expect(
          router.routeInformationProvider.value.uri.path,
          startsWith('/session/'),
        );
      },
    );
  }

  testWidgets('Today and Template detail share a pending start', (
    tester,
  ) async {
    await show(tester, '/');
    final gate = StartingWait();
    fixture.aRepository.waiting = gate;
    await tester.tap(control('/'));
    await tester.runAsync(() => gate.entered.future);
    router.go('/detail');
    await drain(tester);
    expect(enabled(tester, '/detail'), isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(control('/detail'));
    expect(fixture.aRepository.submissions, 1);
    gate.completion.complete();
    await drain(tester);
    expect(enabled(tester, '/detail'), isTrue);
    expect(router.routeInformationProvider.value.uri.path, '/detail');
    // A later deliberate start remains available despite the first workout.
    await tester.tap(control('/detail'));
    await drain(tester);
    expect(fixture.aRepository.submissions, 2);
    expect(
      router.routeInformationProvider.value.uri.path,
      startsWith('/session/'),
    );
  });

  testWidgets(
    'Today preserves template visibility and active-workout availability',
    (tester) async {
      final templates = TemplateRepository(fixture.a);
      final archived = await templates.createTemplate(name: 'Archived');
      await templates.archiveTemplate(archived);
      await show(tester, '/');
      expect(find.text('Archived'), findsNothing);
      expect(control('/'), findsOneWidget);
      final id = await tester.runAsync(
        () => fixture.aRepository.startFromTemplate(StartingFixture.templateId),
      );
      await drain(tester);
      expect(control('/'), findsNothing);
      expect(find.text('Resume'), findsOneWidget);
      expect(
        (await tester.runAsync(
          () => fixture.aRepository.watchSession(id!).first,
        ))!.status,
        SessionStatus.active,
      );
    },
  );

  testWidgets('Template detail keeps its start hidden for an empty template', (
    tester,
  ) async {
    await TemplateRepository(fixture.a).deleteExercise('press');
    await show(tester, '/detail');
    expect(control('/detail'), findsNothing);
  });
}

Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}
