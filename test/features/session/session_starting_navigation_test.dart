import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:quadrille/features/today/presentation/today_screen.dart';
import 'session_starting_fixture.dart';

class AfterCommitRepository extends StartingRepository {
  AfterCommitRepository(super.db);
  final committed = Completer<String>();
  final release = Completer<void>();
  @override
  Future<String> startFromTemplate(String templateId) async {
    final id = await super.startFromTemplate(templateId);
    committed.complete(id);
    await release.future;
    return id;
  }
}

void main() {
  testWidgets(
    'current Today success opens its workout after active-session emission',
    (tester) async {
      final fixture = StartingFixture();
      await fixture.open();
      final repository = AfterCommitRepository(fixture.a);
      fixture.aRepository = repository;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (_, _) => const NoTransitionPage(child: TodayScreen()),
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
      addTearDown(() async {
        if (!repository.release.isCompleted) repository.release.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        await drain(tester);
        router.dispose();
        await fixture.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await drain(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Push A'));
      final id = await tester.runAsync(() => repository.committed.future);
      await drain(tester);
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
      repository.release.complete();
      await drain(tester);
      expect(router.routeInformationProvider.value.uri.path, '/session/$id');
    },
  );
}
