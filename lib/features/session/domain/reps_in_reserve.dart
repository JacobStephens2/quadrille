/// Quick-entry RIR choices and their persisted RPE equivalents.
enum RepsInReserve {
  zero(10, '0'),
  one(9, '1'),
  two(8, '2'),
  threeOrMore(7, '3+');

  const RepsInReserve(this.rpe, this.label);

  final double rpe;
  final String label;

  static RepsInReserve? fromRpe(double rpe) =>
      values.where((choice) => choice.rpe == rpe).firstOrNull;
}
