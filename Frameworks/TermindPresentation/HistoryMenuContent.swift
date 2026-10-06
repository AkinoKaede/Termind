import SwiftUI
import TermindApplication

/// macOS 27 follows the sparse menu style; older systems and iPad show symbols.
public struct HistoryMenuLabel: View {
    private let title: Text
    private let symbol: String

    public init(_ title: LocalizedStringResource, symbol: String) {
        self.title = Text(title)
        self.symbol = symbol
    }

    public init(verbatim title: String, symbol: String) {
        self.title = Text(verbatim: title)
        self.symbol = symbol
    }

    public var body: some View {
        #if os(macOS)
            if #available(macOS 27.0, *) {
                title
            } else {
                Label {
                    title
                } icon: {
                    Image(systemName: symbol)
                }
            }
        #else
            Label {
                title
            } icon: {
                Image(systemName: symbol)
            }
        #endif
    }
}

/// The two optional record sections, each with its own leading separator.
public struct HistoryMenuRecords: View {
    private let snapshot: ConnectionHistoryMenuSnapshot
    private let open: (ConnectionHistoryMenuRow) -> Void
    private let image: (String) -> Image
    @Environment(\.locale) private var locale

    public init(
        snapshot: ConnectionHistoryMenuSnapshot,
        image: @escaping (String) -> Image = { Image(systemName: $0) },
        open: @escaping (ConnectionHistoryMenuRow) -> Void
    ) {
        self.snapshot = snapshot
        self.image = image
        self.open = open
    }

    public var body: some View {
        if !snapshot.recentToday.isEmpty {
            Divider()
            rows(snapshot.recentToday)
        }
        if !snapshot.days.isEmpty {
            Divider()
            ForEach(snapshot.days) { day in
                Menu {
                    rows(day.rows)
                } label: {
                    if day.isToday {
                        HistoryMenuLabel(AppStrings.History.earlierToday, symbol: "clock")
                    } else {
                        HistoryMenuLabel(
                            verbatim: day.date.formatted(.dateTime.year().month().day().locale(locale)),
                            symbol: "calendar")
                    }
                }
            }
        }
    }

    private func rows(_ rows: [ConnectionHistoryMenuRow]) -> some View {
        ForEach(rows) { row in
            Button {
                open(row)
            } label: {
                Label {
                    Text(verbatim: row.host.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    image(row.entry.kind.symbol)
                }
            }
            .disabled(!row.canOpen)
        }
    }
}
