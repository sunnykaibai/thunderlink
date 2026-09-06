import Foundation
import Network

func writeLine(_ value: String) {
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
}

let queue = DispatchQueue(label: "com.sunny.thunderlink.browser-diagnostic")
let browser = NWBrowser(
    for: .bonjour(type: "_thunderlink._tcp", domain: "local."),
    using: .tcp
)

browser.stateUpdateHandler = { state in
    writeLine("STATE \(state)")
}

browser.browseResultsChangedHandler = { results, changes in
    writeLine("RESULTS count=\(results.count) changes=\(changes.count)")
    for result in results {
        let interfaces = result.interfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
        writeLine("ENDPOINT \(result.endpoint.debugDescription)")
        writeLine("INTERFACES [\(interfaces)]")
    }
}

browser.start(queue: queue)
RunLoop.current.run(until: Date().addingTimeInterval(8))
browser.cancel()
