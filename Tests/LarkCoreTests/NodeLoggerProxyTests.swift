import Foundation
import Testing
@testable import LarkCore

// Port of node-sdk `logger/__tests__/logger-proxy.ts` (LoggerProxy).

@Suite struct NodeLoggerProxyTests {
    @Test("logger-proxy: filter work")
    func filterWork() {
        let sink = RecordingLogger()

        // Same level.
        var proxy = LoggerProxy(level: .info, sink: sink)
        proxy.info("info")
        #expect(sink.messages(.info) == ["info"])
        sink.clear()

        // Lower (more verbose) level than configured.
        proxy = LoggerProxy(level: .warn, sink: sink)
        proxy.debug("debug")
        #expect(sink.messages(.warn).isEmpty)
        #expect(sink.messages(.debug).isEmpty)
        sink.clear()

        // Higher (more severe) level than configured.
        proxy = LoggerProxy(level: .trace, sink: sink)
        proxy.error("error")
        #expect(sink.messages(.error) == ["error"])
        #expect(sink.messages(.trace).isEmpty)
    }
}
