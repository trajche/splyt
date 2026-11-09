import Foundation

/// A network reported by `netbird networks list`.
public struct NetBirdNetwork: Identifiable, Hashable, Sendable {
    public var id: String
    public var ranges: [String]
    public var isSelected: Bool

    public init(id: String, ranges: [String], isSelected: Bool) {
        self.id = id
        self.ranges = ranges
        self.isSelected = isSelected
    }

    /// True for a network that carries the default route, which is what an
    /// exit node is.
    public var isExitNode: Bool {
        ranges.contains("0.0.0.0/0") || ranges.contains("::/0")
    }

    /// Parses the CLI's text output. The CLI offers no structured format for this.
    public static func parse(_ output: String) -> [NetBirdNetwork] {
        var networks: [NetBirdNetwork] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ID:") {
                let id = line.dropFirst("- ID:".count).trimmingCharacters(in: .whitespaces)
                networks.append(NetBirdNetwork(id: id, ranges: [], isSelected: false))
            } else if line.hasPrefix("Network:"), !networks.isEmpty {
                networks[networks.count - 1].ranges = line.dropFirst("Network:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("Status:"), !networks.isEmpty {
                let status = line.dropFirst("Status:".count).trimmingCharacters(in: .whitespaces)
                networks[networks.count - 1].isSelected = status == "Selected"
            }
        }
        return networks
    }
}
