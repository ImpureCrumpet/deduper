import Foundation

/// Template for renaming keepers during merge.
/// Applied to the filename stem; extension is always preserved.
public struct RenameTemplate: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case keepOriginal
        case prefix
        case suffix
        case replace
        case custom
    }

    public enum CollisionPolicy: String, Codable, Sendable,
        CaseIterable
    {
        /// Append "-1", "-2", etc. to avoid collision.
        case appendNumber
        /// Leave original name, log warning.
        case skip
        /// Mark decision as blocked.
        case block
    }

    public var mode: Mode
    public var value: String
    public var findText: String
    public var replaceText: String
    public var collisionPolicy: CollisionPolicy

    public init(
        mode: Mode = .keepOriginal,
        value: String = "",
        findText: String = "",
        replaceText: String = "",
        collisionPolicy: CollisionPolicy = .appendNumber
    ) {
        self.mode = mode
        self.value = value
        self.findText = findText
        self.replaceText = replaceText
        self.collisionPolicy = collisionPolicy
    }

    /// Apply template to a filename stem (no extension).
    public func apply(to stem: String) -> String {
        switch mode {
        case .keepOriginal:
            return stem
        case .prefix:
            return value + stem
        case .suffix:
            return stem + value
        case .replace:
            guard !findText.isEmpty else { return stem }
            return stem.replacingOccurrences(
                of: findText, with: replaceText
            )
        case .custom:
            return value.isEmpty ? stem : value
        }
    }

    /// Preview result for a full filename (preserves extension).
    public func preview(for fileName: String) -> String {
        let nsName = fileName as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        let newStem = apply(to: stem)
        if ext.isEmpty {
            return newStem
        }
        return "\(newStem).\(ext)"
    }

    /// Preview for a companion file (same stem transform, different ext).
    public func previewCompanion(
        keeperFileName: String,
        companionFileName: String
    ) -> String {
        let companionExt = (companionFileName as NSString)
            .pathExtension
        let keeperStem = (keeperFileName as NSString)
            .deletingPathExtension
        let newStem = apply(to: keeperStem)
        if companionExt.isEmpty {
            return newStem
        }
        return "\(newStem).\(companionExt)"
    }
}
