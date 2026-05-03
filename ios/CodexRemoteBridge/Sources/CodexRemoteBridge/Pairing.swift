import Foundation

struct Pairing: Equatable {
    let host: String
    let port: Int
    let token: String
    let usesTLS: Bool
    let label: String?

    var id: String {
        bridgeIdentifier(host: host, port: port, usesTLS: usesTLS)
    }

    var websocketURL: URL {
        var components = URLComponents()
        components.scheme = usesTLS ? "wss" : "ws"
        components.host = host
        components.port = port
        components.path = "/"
        return components.url!
    }

    init(host: String, port: Int, token: String, usesTLS: Bool = false, label: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
        self.usesTLS = usesTLS
        self.label = label
    }

    init(uri: String) throws {
        guard let components = URLComponents(string: uri),
              ["maludex", "codex-remote"].contains(components.scheme ?? ""),
              components.host == "pair" else {
            throw PairingError.invalidURI
        }

        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard let host = query["host"],
              let portText = query["port"],
              let port = Int(portText),
              let token = query["token"],
              token.utf8.count >= 32 else {
            throw PairingError.missingFields
        }

        self.host = host
        self.port = port
        self.token = token
        self.usesTLS = query["tls"] == "1"
        self.label = query["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

func bridgeIdentifier(host: String, port: Int, usesTLS: Bool) -> String {
    let scheme = usesTLS ? "wss" : "ws"
    return "\(scheme)://\(host):\(port)"
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum PairingError: LocalizedError {
    case invalidURI
    case missingFields

    var errorDescription: String? {
        switch self {
        case .invalidURI:
            return "Pairing URI must start with maludex://pair."
        case .missingFields:
            return "Pairing URI is missing host, port, or a high-entropy token."
        }
    }
}
