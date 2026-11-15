import 'package:flutter_test/flutter_test.dart';
import 'package:quadrille/features/session/primer_controller.dart';

void main() {
  test('primer runs four consecutive 60-second steps by deadline', () {
    var now = DateTime(2026);
    final primer = PrimerController(now: () => now);
    addTearDown(primer.dispose);
    expect(primer.hasStarted, isFalse);
    primer.start();
    expect(primer.step.name, 'Thoracic Windmills / Open-Books');
    expect(primer.remaining, const Duration(seconds: 60));
    now = now.add(const Duration(seconds: 60));
    primer.refresh();
    expect(
      primer.step.name,
      'Supinated Band Pull-Aparts + Scapular Wall Slides',
    );
    expect(primer.remaining, const Duration(seconds: 60));
    now = now.add(const Duration(seconds: 60));
    primer.refresh();
    expect(
      primer.step.name,
      'Standing Ribcage Circles / Thoracic Circumduction',
    );
    now = now.add(const Duration(seconds: 60));
    primer.refresh();
    expect(primer.step.name, 'Deep Squat Pry + Ankle Rocks');
    expect(primer.isComplete, isFalse);
    now = now.add(const Duration(seconds: 60));
    primer.refresh();
    expect(primer.isComplete, isTrue);
  });

  test('pause retains remaining time and skipping preserves the pause', () {
    var now = DateTime(2026);
    final primer = PrimerController(now: () => now);
    addTearDown(primer.dispose);
    primer.start();
    now = now.add(const Duration(seconds: 17));
    primer.pause();
    now = now.add(const Duration(minutes: 5));
    primer.refresh();
    expect(primer.isPaused, isTrue);
    expect(primer.remaining, const Duration(seconds: 43));
    primer.skipStep();
    expect(primer.stepNumber, 2);
    expect(primer.isPaused, isTrue);
    expect(primer.remaining, const Duration(seconds: 60));
    primer.resume();
    now = now.add(const Duration(seconds: 60));
    primer.refresh();
    expect(primer.stepNumber, 3);
    expect(primer.remaining, const Duration(seconds: 60));
    primer.skipStep();
    expect(primer.stepNumber, 4);
    primer.skipStep();
    expect(primer.isComplete, isTrue);
  });

  test('a delayed tick catches up without extending the primer', () {
    var now = DateTime(2026);
    final primer = PrimerController(now: () => now);
    addTearDown(primer.dispose);
    primer.start();
    now = now.add(const Duration(seconds: 130));
    primer.refresh();
    expect(primer.stepNumber, 3);
    expect(primer.remaining, const Duration(seconds: 50));
    now = now.add(const Duration(seconds: 110));
    primer.refresh();
    expect(primer.isComplete, isTrue);
  });
}
