import Foundation

/// Log levels, ordered from least to most verbose (mirrors the Node SDK).
public enum LarkLogLevel: Int, Sendable, Comparable, CaseIterable {
    case fatal = 0
    case error
    case warn
    case info
    case debug
    case trace

    public static func < (lhs: LarkLogLevel, rhs: LarkLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .fatal: return "fatal"
        case .error: return "error"
        case .warn: return "warn"
        case .info: return "info"
        case .debug: return "debug"
        case .trace: return "trace"
        }
    }
}

/// Logging sink. Implement this to bridge into swift-log, os.Logger, etc.
public protocol LarkLogger: Sendable {
    func log(level: LarkLogLevel, message: String)
}

/// Writes log lines to standard error.
public struct ConsoleLarkLogger: LarkLogger {
    public init() {}
    public func log(level: LarkLogLevel, message: String) {
        let line = "[\(level.label)]: \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// Discards everything.
public struct SilentLarkLogger: LarkLogger {
    public init() {}
    public func log(level: LarkLogLevel, message: String) {}
}

/// Level-filtering wrapper used internally by all SDK components.
public struct LoggerProxy: Sendable {
    public let level: LarkLogLevel
    public let sink: any LarkLogger

    public init(level: LarkLogLevel = .info, sink: any LarkLogger = ConsoleLarkLogger()) {
        self.level = level
        self.sink = sink
    }

    @inlinable public func enabled(_ l: LarkLogLevel) -> Bool { l <= level }

    public func error(_ message: @autoclosure () -> String) { if enabled(.error) { sink.log(level: .error, message: message()) } }
    public func warn(_ message: @autoclosure () -> String) { if enabled(.warn) { sink.log(level: .warn, message: message()) } }
    public func info(_ message: @autoclosure () -> String) { if enabled(.info) { sink.log(level: .info, message: message()) } }
    public func debug(_ message: @autoclosure () -> String) { if enabled(.debug) { sink.log(level: .debug, message: message()) } }
    public func trace(_ message: @autoclosure () -> String) { if enabled(.trace) { sink.log(level: .trace, message: message()) } }
}
