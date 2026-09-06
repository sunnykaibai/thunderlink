import Foundation
import Network

struct DiscoveredPeer: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let interface: NWInterface
}

final class PeerBrowser {
    var onPeersChanged: (([DiscoveredPeer]) -> Void)?
    var onStateChanged: ((String) -> Void)?
    private var browser: NWBrowser?

    deinit { browser?.cancel() }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: "_thunderlink._tcp", domain: "local."),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            switch state {
            case .ready: self.onStateChanged?("正在通过 bridge0 查找另一台 Mac")
            case .failed(let error):
                self.stop()
                self.onStateChanged?("发现服务失败：\(error.localizedDescription)")
            case .waiting(let error): self.onStateChanged?("等待雷电网络：\(error.localizedDescription)")
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            let discovered = results.compactMap { result -> DiscoveredPeer? in
                guard let interface = result.interfaces.first(where: { $0.name == "bridge0" }) else {
                    return nil
                }
                let name: String
                switch result.endpoint {
                case .service(let serviceName, _, _, _): name = serviceName
                default: name = result.endpoint.debugDescription
                }
                return DiscoveredPeer(
                    id: result.endpoint.debugDescription + "@bridge0",
                    name: name,
                    endpoint: result.endpoint,
                    interface: interface
                )
            }
            var byID: [String: DiscoveredPeer] = [:]
            for peer in discovered { byID[peer.id] = peer }
            let peers = byID.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            self.onPeersChanged?(peers)
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        let previous = browser
        browser = nil
        previous?.stateUpdateHandler = nil
        previous?.browseResultsChangedHandler = nil
        previous?.cancel()
        onPeersChanged?([])
    }
}
