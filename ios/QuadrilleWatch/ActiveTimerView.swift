import SwiftUI

/// The wrist view: a live countdown to the rest deadline, or an idle state.
/// Recomputes remaining time from the absolute deadline (same wall-clock model
/// as the phone), so it stays correct without the phone streaming ticks.
struct ActiveTimerView: View {
  @EnvironmentObject var connectivity: WatchConnectivityManager

  var body: some View {
    Group {
      if let endsAt = connectivity.restEndsAtMillis {
        let deadline = Date(timeIntervalSince1970: endsAt / 1000.0)
        VStack(spacing: 4) {
          Text(connectivity.exerciseName ?? "Rest")
            .font(.headline)
            .multilineTextAlignment(.center)
          if deadline > Date() {
            Text(timerInterval: Date()...deadline, countsDown: true)
              .font(.system(size: 40, weight: .bold, design: .rounded))
              .monospacedDigit()
          } else {
            Text("Rest complete")
              .font(.title3)
              .foregroundStyle(.green)
          }
        }
        .padding()
      } else {
        VStack(spacing: 6) {
          Image(systemName: "square.grid.3x3.fill")
            .font(.title)
            .foregroundStyle(.secondary)
          Text("No active rest")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
