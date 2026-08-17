import SwiftUI

struct DayCard: View {
    let day: DayVM
    let isBusy: Bool
    let isLoading: Bool
    let onBackfill: () -> Void

    private var canBackfill: Bool {
        !day.isFuture && day.status != .complete && !isBusy && !isLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(day.weekday)
                    .font(.subheadline.bold())
                Spacer()
                statusBadge
            }

            Text(day.dateLabel)
                .font(.callout)
                .foregroundStyle(.secondary)

            if day.isVacation {
                Label("Vacation", systemImage: "sun.max.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
            } else if day.isBankHoliday {
                Label("Bank holiday" + (day.shiftShortName.map { " (\($0))" } ?? ""), systemImage: "flag.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(.gray)
            } else if day.isHoliday {
                Label("Holiday" + (day.shiftShortName.map { " (\($0))" } ?? ""), systemImage: "flag.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
            } else if day.isToday {
                Text("Today")
                    .font(.caption2.bold())
                    .foregroundStyle(.blue)
            }

            punchList
                .frame(height: 84, alignment: .top)

            Spacer()

            Button {
                onBackfill()
            } label: {
                Label("Backfill", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canBackfill)
            .frame(maxWidth: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220, alignment: .topLeading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(day.isToday ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .disabled(isLoading)
        .opacity(isLoading ? 0.5 : 1)
        .overlay {
            if isLoading {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.3))
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: isLoading)
    }

    private var cardBackground: some ShapeStyle {
        if day.isToday {
            return Color.blue.opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch day.status {
        case .complete:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption2.bold())
                .foregroundStyle(.green)
        case .partial:
            Label("Partial", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.bold())
                .foregroundStyle(.orange)
        case .empty:
            Label("Empty", systemImage: "circle.dashed")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var punchList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(day.punches) { punch in
                HStack(spacing: 6) {
                    Text(punch.type == "in" ? "In" : "Out")
                        .font(.caption2.bold())
                        .frame(width: 26, alignment: .leading)
                        .foregroundStyle(punch.type == "in" ? Color.blue : Color.orange)
                    Text(punch.time)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
            if day.punches.isEmpty {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
