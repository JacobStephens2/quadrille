/// Displays whole numbers without a decimal suffix while retaining fractions.
String compactNumber(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();
