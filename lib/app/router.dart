import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/exercises/presentation/exercises_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/session/presentation/active_session_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/templates/presentation/template_detail_screen.dart';
import '../features/templates/presentation/templates_screen.dart';
import '../features/today/presentation/today_screen.dart';

/// The five top-level destinations of the app shell.
enum AppTab {
  today('/', 'Today', Icons.today_outlined, Icons.today),
  templates('/templates', 'Templates', Icons.dashboard_customize_outlined,
      Icons.dashboard_customize),
  history('/history', 'History', Icons.history_outlined, Icons.history),
  exercises('/exercises', 'Exercises', Icons.fitness_center_outlined,
      Icons.fitness_center),
  settings('/settings', 'Settings', Icons.settings_outlined, Icons.settings);

  const AppTab(this.path, this.label, this.icon, this.selectedIcon);

  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// App router: a stateful bottom-navigation shell so each tab keeps its own
/// navigation stack and scroll position.
GoRouter createRouter() {
  return GoRouter(
    initialLocation: AppTab.today.path,
    routes: [
      // Full-screen, outside the tab shell (no bottom nav during a workout).
      GoRoute(
        path: '/session/:id',
        builder: (context, state) =>
            ActiveSessionScreen(sessionId: state.pathParameters['id']!),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            _AppShell(navigationShell: navigationShell),
        branches: [
          _branch(AppTab.today, const TodayScreen()),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppTab.templates.path,
                builder: (_, _) => const TemplatesScreen(),
                routes: [
                  GoRoute(
                    path: ':id',
                    builder: (context, state) => TemplateDetailScreen(
                      templateId: state.pathParameters['id']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          _branch(AppTab.history, const HistoryScreen()),
          _branch(AppTab.exercises, const ExercisesScreen()),
          _branch(AppTab.settings, const SettingsScreen()),
        ],
      ),
    ],
  );
}

StatefulShellBranch _branch(AppTab tab, Widget screen) => StatefulShellBranch(
      routes: [GoRoute(path: tab.path, builder: (_, _) => screen)],
    );

class _AppShell extends StatelessWidget {
  const _AppShell({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 720;

    Widget body = navigationShell;
    if (isWide) {
      // On wide layouts (web/tablet) use a side rail instead of a bottom bar.
      body = Row(
        children: [
          NavigationRail(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _goBranch,
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final tab in AppTab.values)
                NavigationRailDestination(
                  icon: Icon(tab.icon),
                  selectedIcon: Icon(tab.selectedIcon),
                  label: Text(tab.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: navigationShell),
        ],
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: isWide
          ? null
          : NavigationBar(
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: _goBranch,
              destinations: [
                for (final tab in AppTab.values)
                  NavigationDestination(
                    icon: Icon(tab.icon),
                    selectedIcon: Icon(tab.selectedIcon),
                    label: tab.label,
                  ),
              ],
            ),
    );
  }

  void _goBranch(int index) => navigationShell.goBranch(
        index,
        initialLocation: index == navigationShell.currentIndex,
      );
}
