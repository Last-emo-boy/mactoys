import Foundation

/// Wraps an optional setting so `nil` is written as an explicit JSON `null`.
///
/// `SettingsStore.load` overlays the stored JSON on the encoded defaults. A plain `Shortcut?`
/// whose value the user cleared is omitted from the file, so the default comes back on the next
/// launch. Wrapping the property keeps the cleared state:
///
///     @NullCodable var activation: Shortcut? = Shortcut(kVK_ANSI_H, [.control, .option])
@propertyWrapper
public struct NullCodable<Wrapped: Codable & Equatable>: Codable, Equatable {
    public var wrappedValue: Wrapped?

    public init(wrappedValue: Wrapped?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Wrapped.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
    }
}

extension NullCodable: Hashable where Wrapped: Hashable {}
extension NullCodable: Sendable where Wrapped: Sendable {}

extension KeyedDecodingContainer {
    /// A missing key decodes as `nil` instead of failing the whole settings struct.
    public func decode<T>(_ type: NullCodable<T>.Type, forKey key: Key) throws -> NullCodable<T> {
        try decodeIfPresent(type, forKey: key) ?? NullCodable(wrappedValue: nil)
    }
}
