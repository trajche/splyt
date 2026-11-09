import Foundation

/// Server side of a SOCKS5 handshake (RFC 1928) with username and password
/// authentication (RFC 1929). It only parses bytes, so it needs no network to test.
///
/// Password authentication is mandatory. The Direct listener leaves the VPN, so
/// without a secret any local process, or any web page making requests to
/// 127.0.0.1, could use it to step around per-app rules and the kill switch.
public struct SOCKSHandshake {
    public enum Event: Equatable {
        /// Bytes to send to the client.
        case send(Data)
        /// The client asked for this target. `leftover` is data it already sent.
        case connect(host: String, port: UInt16, leftover: Data)
        /// The handshake failed. Send `reply`, if any, then close.
        case reject(reply: Data?)
    }

    public enum Reply: UInt8 {
        case succeeded = 0
        case generalFailure = 1
        case networkUnreachable = 3
        case hostUnreachable = 4
        case commandNotSupported = 7
        case addressTypeNotSupported = 8
    }

    private enum Stage {
        case greeting, authentication, request, done
    }

    public static let username = "splyt"
    private static let version: UInt8 = 5
    private static let methodPassword: UInt8 = 2
    private static let methodNone: UInt8 = 0xFF
    private static let authVersion: UInt8 = 1

    private let password: [UInt8]
    private var stage = Stage.greeting
    private var buffer = [UInt8]()

    public init(password: String) {
        self.password = Array(password.utf8)
    }

    /// Wire format of a reply to a CONNECT request. The bound address is unused by
    /// clients here, so it is always 0.0.0.0:0.
    public static func reply(_ reply: Reply) -> Data {
        Data([version, reply.rawValue, 0, 1, 0, 0, 0, 0, 0, 0])
    }

    public mutating func consume(_ data: Data) -> [Event] {
        buffer.append(contentsOf: data)
        var events: [Event] = []
        while let event = step() {
            events.append(event)
            if stage == .done {
                break
            }
        }
        return events
    }

    private mutating func step() -> Event? {
        switch stage {
        case .greeting:
            return greeting()
        case .authentication:
            return authentication()
        case .request:
            return request()
        case .done:
            return nil
        }
    }

    private mutating func greeting() -> Event? {
        guard buffer.count >= 2 else {
            return nil
        }
        guard buffer[0] == Self.version else {
            stage = .done
            return .reject(reply: nil)
        }
        let length = 2 + Int(buffer[1])
        guard buffer.count >= length else {
            return nil
        }
        let offered = buffer[2..<length]
        buffer.removeFirst(length)
        guard offered.contains(Self.methodPassword) else {
            stage = .done
            return .reject(reply: Data([Self.version, Self.methodNone]))
        }
        stage = .authentication
        return .send(Data([Self.version, Self.methodPassword]))
    }

    private mutating func authentication() -> Event? {
        guard buffer.count >= 2 else {
            return nil
        }
        guard buffer[0] == Self.authVersion else {
            stage = .done
            return .reject(reply: nil)
        }
        let userLength = Int(buffer[1])
        guard buffer.count >= 3 + userLength else {
            return nil
        }
        let passwordLength = Int(buffer[2 + userLength])
        let length = 3 + userLength + passwordLength
        guard buffer.count >= length else {
            return nil
        }
        let user = Array(buffer[2..<(2 + userLength)])
        let secret = Array(buffer[(3 + userLength)..<length])
        buffer.removeFirst(length)
        guard user == Array(Self.username.utf8), Self.constantTimeEqual(secret, password), !password.isEmpty else {
            stage = .done
            return .reject(reply: Data([Self.authVersion, 1]))
        }
        stage = .request
        return .send(Data([Self.authVersion, 0]))
    }

    private mutating func request() -> Event? {
        guard buffer.count >= 5 else {
            return nil
        }
        guard buffer[0] == Self.version else {
            stage = .done
            return .reject(reply: nil)
        }
        guard buffer[1] == 1 else {  // CONNECT only. There is no UDP relay.
            stage = .done
            return .reject(reply: Self.reply(.commandNotSupported))
        }
        let addressLength: Int
        switch buffer[3] {
        case 1:
            addressLength = 4
        case 3:
            addressLength = 1 + Int(buffer[4])
        case 4:
            addressLength = 16
        default:
            stage = .done
            return .reject(reply: Self.reply(.addressTypeNotSupported))
        }
        let length = 4 + addressLength + 2
        guard buffer.count >= length else {
            return nil
        }
        let address = Array(buffer[4..<(4 + addressLength)])
        let port = UInt16(buffer[length - 2]) << 8 | UInt16(buffer[length - 1])
        let host: String?
        switch buffer[3] {
        case 1:
            host = address.map(String.init).joined(separator: ".")
        case 3:
            host = String(bytes: address.dropFirst(), encoding: .utf8)
        default:
            host = stride(from: 0, to: 16, by: 2)
                .map { String(UInt16(address[$0]) << 8 | UInt16(address[$0 + 1]), radix: 16) }
                .joined(separator: ":")
        }
        let leftover = Data(buffer[length...])
        buffer.removeAll()
        stage = .done
        guard let host, !host.isEmpty, port != 0 else {
            return .reject(reply: Self.reply(.hostUnreachable))
        }
        return .connect(host: host, port: port, leftover: leftover)
    }

    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
