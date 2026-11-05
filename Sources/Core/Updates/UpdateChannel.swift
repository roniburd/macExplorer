/// Which Sparkle appcast items the user may receive (spec §3). Release sees only items without a channel;
/// Beta also sees `<sparkle:channel>beta</sparkle:channel>` items. Sparkle always picks the newest allowed item, so
/// moving Beta → Release never downgrades.
public enum UpdateChannel: String, Sendable, Codable, CaseIterable {
    case release, beta

    public var sparkleChannels: Set<String> {
        switch self {
        case .release: []
        case .beta: ["beta"]
        }
    }
}
