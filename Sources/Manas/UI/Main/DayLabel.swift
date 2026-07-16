import Foundation

/// The timeline's shared day vocabulary: adjacent days go by their relative
/// names, everything else reads as weekday + date ("Monday, Jul 13").
enum DayLabel {
    static func title(
        for day: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let target = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: now)
        switch calendar.dateComponents([.day], from: today, to: target).day {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }
}
