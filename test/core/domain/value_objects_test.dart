import 'package:flutter_test/flutter_test.dart';
import 'package:countdown_ring/countdown_ring.dart';
import 'package:quadrille/core/domain/exercise_order.dart';
import 'package:quadrille/core/domain/rep_target.dart';

void main() {
  group('RepTarget', () {
    test('rep range label', () {
      expect(RepTarget.reps(6, 8).label, '6-8');
      expect(RepTarget.fixedReps(5).label, '5');
    });

    test('duration range label', () {
      expect(RepTarget.duration(30, 60).label, '30-60s');
    });

    test('combined reps and duration', () {
      const t = RepTarget(repMin: 8, repMax: 12, durationMin: Duration(seconds: 30));
      expect(t.label, '8-12 · 30s');
    });

    test('empty target', () {
      expect(RepTarget.none.isEmpty, isTrue);
      expect(RepTarget.none.label, '');
    });

    test('value equality', () {
      expect(RepTarget.reps(6, 8), RepTarget.reps(6, 8));
      expect(RepTarget.reps(6, 8) == RepTarget.reps(6, 10), isFalse);
    });
  });

  group('ExerciseOrder', () {
    test('parses bare number', () {
      final o = ExerciseOrder.parse('1');
      expect(o.groupNumber, 1);
      expect(o.variant, isNull);
      expect(o.isSupersetMember, isFalse);
      expect(o.label, '1');
    });

    test('parses superset member', () {
      final o = ExerciseOrder.parse('2A');
      expect(o.groupNumber, 2);
      expect(o.variant, 'A');
      expect(o.isSupersetMember, isTrue);
      expect(o.groupKey, '2');
      expect(o.label, '2A');
    });

    test('lowercase and whitespace tolerated', () {
      expect(ExerciseOrder.parse(' 3 b ').label, '3B');
    });

    test('sorts 1, 2A, 2B, 3', () {
      final orders = ['3', '2B', '1', '2A']
          .map(ExerciseOrder.parse)
          .toList()
        ..sort();
      expect(orders.map((o) => o.label).toList(), ['1', '2A', '2B', '3']);
    });

    test('bare group sorts before lettered variant', () {
      expect(
        ExerciseOrder.parse('2').compareTo(ExerciseOrder.parse('2A')),
        lessThan(0),
      );
    });

    test('unparseable falls back to group 0', () {
      expect(ExerciseOrder.parse('???').groupNumber, 0);
    });
  });

  group('rest duration formatting', () {
    test('compactLabel matches sheet notation', () {
      expect(const Duration(seconds: 90).compactLabel, '90s');
      expect(const Duration(minutes: 2).compactLabel, "2'");
      expect(const Duration(seconds: 150).compactLabel, "2.5'");
      expect(const Duration(minutes: 3).compactLabel, "3'");
      expect(Duration.zero.compactLabel, '0s');
    });

    test('clockLabel is MM:SS', () {
      expect(const Duration(seconds: 84).clockLabel, '01:24');
      expect(const Duration(seconds: -5).clockLabel, '-00:05');
    });

    test('parseDuration handles sheet forms', () {
      expect(parseDuration('90s'), const Duration(seconds: 90));
      expect(parseDuration('90'), const Duration(seconds: 90));
      expect(parseDuration("2'"), const Duration(minutes: 2));
      expect(parseDuration("2.5'"), const Duration(seconds: 150));
      expect(parseDuration('1:30'), const Duration(minutes: 1, seconds: 30));
      expect(parseDuration('1m30s'), const Duration(minutes: 1, seconds: 30));
    });

    test('parseDuration rejects garbage', () {
      expect(parseDuration('abc'), isNull);
      expect(parseDuration(''), isNull);
    });
  });
}
