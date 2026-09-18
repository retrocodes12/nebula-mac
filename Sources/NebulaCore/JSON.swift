import Foundation

/// Add-on and sync documents are loose JSON written by four other clients, so they are read as
/// dictionaries through these helpers rather than through Codable: a missing or mistyped field
/// must degrade to a default, never throw the whole document away.
public typealias JSONObject = [String: Any]

public enum JSON {
    public static func object(_ data: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? JSONObject
    }

    public static func object(_ text: String) -> JSONObject? {
        guard let d = text.data(using: .utf8) else { return nil }
        return object(d)
    }

    public static func data(_ o: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    public static func text(_ o: Any) -> String {
        String(data: data(o), encoding: .utf8) ?? "{}"
    }
}

public extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber, !(self[k] is Bool) { return n.stringValue }
        return ""
    }

    /// A non-empty string, else nil.
    func text(_ k: String) -> String? {
        let s = str(k)
        return s.isEmpty ? nil : s
    }

    func num(_ k: String) -> Double {
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let s = self[k] as? String, let d = Double(s) { return d }
        return 0
    }

    func int(_ k: String) -> Int { Int(num(k)) }
    func int64(_ k: String) -> Int64 { Int64(num(k)) }

    func optInt(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String, let i = Int(s) { return i }
        return nil
    }

    func bool(_ k: String) -> Bool {
        if let b = self[k] as? Bool { return b }
        if let n = self[k] as? NSNumber { return n.intValue != 0 }
        return false
    }

    func obj(_ k: String) -> JSONObject? { self[k] as? JSONObject }
    func arr(_ k: String) -> [Any] { self[k] as? [Any] ?? [] }
    func objs(_ k: String) -> [JSONObject] { arr(k).compactMap { $0 as? JSONObject } }
    func strs(_ k: String) -> [String]? {
        guard let a = self[k] as? [Any] else { return nil }
        return a.compactMap { $0 as? String }
    }
}

public func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
