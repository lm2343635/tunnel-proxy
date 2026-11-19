import Network
import SwiftUI

@main
struct RoutingProbe: App {
    @StateObject private var probe = ProbeConnection()
    private let endpoint = LabEndpoint.selected

    var body: some Scene {
        WindowGroup("Routing Probe") {
            VStack(alignment: .leading, spacing: 12) {
                if let endpoint {
                    Text("Synthetic echo test at \(endpoint.description)")
                    HStack {
                        Button("Send TCP probe") { probe.send(to: endpoint, using: .tcp) }
                        Button("Send UDP probe") { probe.send(to: endpoint, using: .udp) }
                    }
                    .disabled(probe.running)
                } else {
                    Text("Invalid loopback port. Use a port from 49152 to 65535.")
                }
                Text(probe.result).textSelection(.enabled)
            }
            .padding(20)
            .frame(minWidth: 420)
        }
    }
}

final class ProbeConnection: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var result = "Ready"

    private var connection: NWConnection?

    func send(to endpoint: LabEndpoint, using parameters: NWParameters) {
        let target = NWEndpoint.hostPort(host: .init(endpoint.address),
                                        port: .init(rawValue: endpoint.port)!)
        let connection = NWConnection(to: target, using: parameters)
        let marker = UUID().uuidString
        let payload = Data(marker.utf8)
        self.connection = connection
        running = true
        result = "Waiting for echo · \(marker)"
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if error != nil {
                        self.finish(connection, "Send failed")
                    } else {
                        connection.receive(minimumIncompleteLength: payload.count,
                                           maximumLength: payload.count) { response, _, _, _ in
                            self.finish(connection, response == payload ? "Echo received" : "Echo missing or mismatched")
                        }
                    }
                })
            case .failed: finish(connection, "Connection failed")
            default: break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let connection else { return }
            self?.finish(connection, "Probe timed out")
        }
    }

    private func finish(_ connection: NWConnection, _ outcome: String) {
        guard self.connection === connection else { return }
        result += "\n\(outcome)"
        connection.stateUpdateHandler = nil
        connection.cancel()
        self.connection = nil
        running = false
    }
}
