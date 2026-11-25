import Foundation

/// Resilient WebSocket connection to `/ws` with heartbeat + exponential backoff reconnects.
@MainActor
final class RelaySocket {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case disconnected
    }

    var onEvent: ((Data) -> Void)?
    var onStateChange: ((State) -> Void)?
    /// Fired after a successful reconnect, so the store can resync anything missed.
    var onReconnected: (() -> Void)?

    private(set) var state: State = .idle {
        didSet {
            if oldValue != state { onStateChange?(state) }
        }
    }

    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var request: URLRequest?
    private var generation = 0
    private var attempts = 0
    private var everConnected = false
    private var shouldRun = false
    private var heartbeat: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    func connect(_ request: URLRequest) {
        self.request = request
        shouldRun = true
        attempts = 0
        everConnected = false
        open()
    }

    func disconnect() {
        shouldRun = false
        generation += 1
        heartbeat?.cancel()
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
    }

    /// Re-open immediately (e.g. on returning to foreground) if not healthy.
    func ensureConnected() {
        guard shouldRun else { return }
        if state != .connected {
            attempts = 0
            open()
        } else {
            sendPing()
        }
    }

    private func open() {
        guard shouldRun, let request else { return }
        reconnectTask?.cancel()
        heartbeat?.cancel()
        task?.cancel(with: .goingAway, reason: nil)

        generation += 1
        let gen = generation
        let newTask = session.webSocketTask(with: request)
        newTask.maximumMessageSize = 16 * 1024 * 1024
        task = newTask
        state = .connecting
        newTask.resume()

        receiveLoop(newTask, generation: gen)
        startHeartbeat(generation: gen)
        sendPing()
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask, generation gen: Int) {
        Task { [weak self] in
            while true {
                do {
                    let message = try await socket.receive()
                    guard let self, self.generation == gen else { return }
                    self.markConnected()
                    switch message {
                    case .string(let text):
                        self.onEvent?(Data(text.utf8))
                    case .data(let data):
                        self.onEvent?(data)
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self, self.generation == gen else { return }
                    self.handleFailure()
                    return
                }
            }
        }
    }

    private func markConnected() {
        guard state != .connected else { return }
        let wasReconnect = everConnected
        everConnected = true
        attempts = 0
        state = .connected
        if wasReconnect { onReconnected?() }
    }

    private func startHeartbeat(generation gen: Int) {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                self.sendPing()
            }
        }
    }

    private func sendPing() {
        guard let socket = task else { return }
        let gen = generation
        Task { [weak self] in
            do {
                try await socket.send(.string("{\"type\":\"ping\"}"))
            } catch {
                guard let self, self.generation == gen else { return }
                self.handleFailure()
            }
        }
    }

    private func handleFailure() {
        heartbeat?.cancel()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        generation += 1
        guard shouldRun else {
            state = .idle
            return
        }
        state = .disconnected
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        attempts += 1
        let base = min(30.0, pow(2.0, Double(min(attempts, 6))) * 0.5)
        let delay = base + Double.random(in: 0...0.6)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.shouldRun else { return }
            self.open()
        }
    }
}
