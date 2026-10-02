import SwiftUI

struct MetricsFigure: View {
    let title: LocalizedStringResource
    let value: String
    let color: Color

    init(_ title: LocalizedStringResource, value: String, color: Color = .primary) {
        self.title = title
        self.value = value
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
