import Combine
import Foundation
import Testing
import ContextCore
@testable import ContextDesk

private func status(detail: String = "Connected", requests: Int) throws -> PluginStatus {
    let json = #"{"protocolVersion":1,"pluginID":"example","pluginVersion":"1","instance":"test","detail":"\#(detail)","metrics":[{"id":"requests","title":"Requests","value":\#(requests)}]}"#
    return try JSONDecoder().decode(PluginStatus.self, from: Data(json.utf8))
}

@MainActor @Test func metricsOnlyChangeDoesNotPublishPluginStatuses() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(pluginDirectory: root)
    var statusPublications = 0, metricPublications = 0
    let statuses = model.$pluginStatuses.dropFirst().sink { _ in statusPublications += 1 }
    let metrics = model.pluginMetrics.objectWillChange.sink { metricPublications += 1 }
    defer { statuses.cancel(); metrics.cancel() }

    model.applyPluginStatus(try status(requests: 1), for: "example")
    #expect(statusPublications == 1 && metricPublications == 1)
    #expect(model.pluginMetrics.metrics["example"]?.map(\.value) == [1])
    // A counter tick reaches the metrics only.
    model.applyPluginStatus(try status(requests: 2), for: "example")
    #expect(statusPublications == 1 && metricPublications == 2)
    #expect(model.pluginMetrics.metrics["example"]?.map(\.value) == [2])
    // The same status again publishes nothing.
    model.applyPluginStatus(try status(requests: 2), for: "example")
    #expect(statusPublications == 1 && metricPublications == 2)
    // A changed detail is a status change; a lost plugin clears both.
    model.applyPluginStatus(try status(detail: "Degraded", requests: 2), for: "example")
    #expect(statusPublications == 2 && model.pluginStatuses["example"]?.detail == "Degraded")
    model.applyPluginStatus(nil, for: "example")
    #expect(model.pluginStatuses["example"] == nil && model.pluginMetrics.metrics["example"] == nil)
}

@Test func idlePluginsArePolledTwiceAMinute() {
    #expect(DeskModel.pluginPollDue(routeInUse: true, sinceLastPoll: .seconds(5)))
    #expect(!DeskModel.pluginPollDue(routeInUse: false, sinceLastPoll: .seconds(25)))
    #expect(DeskModel.pluginPollDue(routeInUse: false, sinceLastPoll: .seconds(30)))
}
