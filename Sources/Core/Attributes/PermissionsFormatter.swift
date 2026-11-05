import MacxFS

/// `ls -l` style permissions ("drwxr-xr-x"), including setuid/setgid/sticky as s/S/t/T. Pure.
public enum PermissionsFormatter {
    public static func string(mode: UInt16, kind: Kind) -> String {
        let type: Character = switch kind {
        case .directory, .package: "d"
        case .symlink: "l"
        default: "-"
        }
        var c: [Character] = [type]
        let bits: [(UInt16, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"),
                                           (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x")]
        for (bit, ch) in bits { c.append(mode & bit != 0 ? ch : "-") }
        if mode & 0o4000 != 0 { c[3] = c[3] == "x" ? "s" : "S" }
        if mode & 0o2000 != 0 { c[6] = c[6] == "x" ? "s" : "S" }
        if mode & 0o1000 != 0 { c[9] = c[9] == "x" ? "t" : "T" }
        return String(c)
    }
}
