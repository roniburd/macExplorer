/// Per-folder Group by mode (spec §11). Grouping applies to the Details view only; Icons and Columns ignore it.
public enum GroupBy: String, Sendable, Codable, CaseIterable { case none, kind, dateModified, size, nameFirstLetter }
