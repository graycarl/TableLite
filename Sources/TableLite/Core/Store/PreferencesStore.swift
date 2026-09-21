import Foundation

/// 偏好设置的持久化层。
///
/// `02-persistence.md` §6：所有键在 `PreferenceKey` 集中声明并给出默认值；
/// **本类型是唯一直接读写 `KeyValueStore` 的地方**，视图与 ViewModel 不得绕过它。
///
/// 面向 UI 的可观察对象是 `Preferences`；`PreferencesStore` 只负责「读默认值 / 写回」。
@MainActor
public final class PreferencesStore {

    private let store: KeyValueStore

    public init(store: KeyValueStore = UserDefaultsKeyValueStore()) {
        self.store = store
    }

    // MARK: - 读取（缺失时取 `PreferenceKey` 的默认值）

    public func bool(_ key: PreferenceKey) -> Bool {
        (store.object(forKey: key.rawValue) as? Bool) ?? (key.defaultValue as? Bool ?? false)
    }

    public func integer(_ key: PreferenceKey) -> Int {
        (store.object(forKey: key.rawValue) as? Int) ?? (key.defaultValue as? Int ?? 0)
    }

    public func double(_ key: PreferenceKey) -> Double {
        (store.object(forKey: key.rawValue) as? Double) ?? (key.defaultValue as? Double ?? 0)
    }

    public func string(_ key: PreferenceKey) -> String {
        (store.object(forKey: key.rawValue) as? String) ?? (key.defaultValue as? String ?? "")
    }

    /// 枚举以 `rawValue` 存储；存储值不可识别时回落到默认值（再不行用 `fallback`）。
    public func choice<T: RawRepresentable>(
        _ key: PreferenceKey,
        _ type: T.Type,
        fallback: T
    ) -> T where T.RawValue == String {
        if let raw = store.object(forKey: key.rawValue) as? String, let value = T(rawValue: raw) {
            return value
        }
        if let raw = key.defaultValue as? String, let value = T(rawValue: raw) {
            return value
        }
        return fallback
    }

    // MARK: - 写入

    public func set(_ value: Any?, for key: PreferenceKey) {
        store.set(value, forKey: key.rawValue)
    }

    public func setChoice<T: RawRepresentable>(_ value: T, for key: PreferenceKey) where T.RawValue == String {
        store.set(value.rawValue, forKey: key.rawValue)
    }

    // MARK: - 重置

    /// 清空全部键，让后续读取回到默认值。
    public func resetAll() {
        for key in PreferenceKey.allCases {
            store.removeObject(forKey: key.rawValue)
        }
    }
}
