import Foundation

/// 键值存储的注入点。
///
/// 真实实现包 `UserDefaults`（`02-persistence.md` §1：`com.graycarl.tablelite`）；
/// 单测用 `InMemoryKeyValueStore`，避免污染真实偏好。
///
/// 只在 `@MainActor` 上使用：偏好与工作区状态都属于 UI 状态（`01-architecture.md` §3.5）。
@MainActor
public protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

/// 基于 `UserDefaults` 的实现。
@MainActor
public final class UserDefaultsKeyValueStore: KeyValueStore {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func object(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    public func set(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// 单测 / 预览用的内存实现。
@MainActor
public final class InMemoryKeyValueStore: KeyValueStore {

    private var storage: [String: Any]

    public init(storage: [String: Any] = [:]) {
        self.storage = storage
    }

    public func object(forKey key: String) -> Any? {
        storage[key]
    }

    public func set(_ value: Any?, forKey key: String) {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    public func removeObject(forKey key: String) {
        storage.removeValue(forKey: key)
    }
}
