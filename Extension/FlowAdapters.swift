import Foundation
import Network
import NetworkExtension
import SplytCore

final class TCPFlowAdapter: TCPFlowIO {
    private let flow: NEAppProxyTCPFlow

    init(_ flow: NEAppProxyTCPFlow) {
        self.flow = flow
    }

    func open(completion: @escaping (Error?) -> Void) {
        flow.open(withLocalFlowEndpoint: nil, completionHandler: completion)
    }

    func read(completion: @escaping (Data?, Error?) -> Void) {
        flow.readData(completionHandler: completion)
    }

    func write(_ data: Data, completion: @escaping (Error?) -> Void) {
        flow.write(data, withCompletionHandler: completion)
    }

    func closeRead(error: Error?) {
        flow.closeReadWithError(error)
    }

    func closeWrite(error: Error?) {
        flow.closeWriteWithError(error)
    }
}

final class UDPFlowAdapter: UDPFlowIO {
    private let flow: NEAppProxyUDPFlow

    init(_ flow: NEAppProxyUDPFlow) {
        self.flow = flow
    }

    func open(completion: @escaping (Error?) -> Void) {
        flow.open(withLocalFlowEndpoint: flow.localFlowEndpoint, completionHandler: completion)
    }

    func readDatagrams(completion: @escaping ([(Data, Network.NWEndpoint)]?, Error?) -> Void) {
        flow.readDatagrams(completionHandler: completion)
    }

    func writeDatagrams(_ datagrams: [(Data, Network.NWEndpoint)], completion: @escaping (Error?) -> Void) {
        flow.writeDatagrams(datagrams, completionHandler: completion)
    }

    func closeRead(error: Error?) {
        flow.closeReadWithError(error)
    }

    func closeWrite(error: Error?) {
        flow.closeWriteWithError(error)
    }
}
