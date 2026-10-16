import CheckmateApplication
import CheckmateDomain
import CryptoKit
import Foundation
@preconcurrency import Network
import Security
/// The TLS settings the LAN-play spike proved on the test hosts and on macOS 26 and 14 (D3; `Tools/lan-spike.swift`):
/// TLS 1.2 only, ECDHE-PSK with ChaCha20-Poly1305 (0xCCAC) as the one suite offered, the PSK derived from the code,
/// tickets and resumption off, no peer-to-peer Wi-Fi. Both ends read the negotiated version and suite from the
/// metadata and close anything else.
public enum NetworkTLS {
    public static let pinnedSuite:UInt16=0xCCAC
    /// TLS 1.2 on the wire.
    public static let pinnedVersion:UInt16=0x0303
    /// HKDF-SHA256: input key material the code, salt the game ID, info "checkmate-lan v1 seat" or "… watch".
    public static func preSharedKey(_ key:NetworkAccessKey)->SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial:SymmetricKey(data:Data(key.code.text.utf8)),salt:Data(key.gameID.text.utf8),info:Data(key.info.utf8),outputByteCount:32)
    }
    /// The same parameters on both ends; the PSK identity is the game ID. `loopback` binds a listener to 127.0.0.1,
    /// which is outside local-network privacy (D12).
    static func parameters(_ key:NetworkAccessKey,loopback:Bool)->NWParameters {
        let tls=NWProtocolTLS.Options()
        let security=tls.securityProtocolOptions
        let secret=preSharedKey(key).withUnsafeBytes{DispatchData(bytes:$0)}
        let identity=Data(key.gameID.text.utf8).withUnsafeBytes{DispatchData(bytes:$0)}
        sec_protocol_options_add_pre_shared_key(security,secret as __DispatchData,identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(security,tls_ciphersuite_t(rawValue:pinnedSuite)!)
        sec_protocol_options_set_min_tls_protocol_version(security,.TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security,.TLSv12)
        sec_protocol_options_set_tls_tickets_enabled(security,false)
        sec_protocol_options_set_tls_resumption_enabled(security,false)
        let tcp=NWProtocolTCP.Options()
        tcp.connectionTimeout=5
        let parameters=NWParameters(tls:tls,tcp:tcp)
        parameters.includePeerToPeer=false
        if loopback {parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)}
        return parameters
    }
    /// What TLS negotiated on a ready connection, from `sec_protocol_metadata`.
    public struct Negotiated:Equatable {
        public let version:UInt16,suite:UInt16
        public var pinned:Bool {version==NetworkTLS.pinnedVersion && suite==NetworkTLS.pinnedSuite}
    }
    static func negotiated(_ connection:NWConnection)->Negotiated? {
        guard let metadata=connection.metadata(definition:NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else{return nil}
        let security=metadata.securityProtocolMetadata
        return Negotiated(version:UInt16(sec_protocol_metadata_get_negotiated_tls_protocol_version(security).rawValue),suite:UInt16(sec_protocol_metadata_get_negotiated_tls_ciphersuite(security).rawValue))
    }
    /// TN3179's two denial signals: DNS error -65570 (kDNSServiceErr_PolicyDenied), or a path unsatisfied because local
    /// network access is denied (D11). Nothing else is read as denial.
    static func deniesLocalNetwork(_ error:NWError,path:NWPath?)->Bool {
        if case .dns(let code)=error,code == -65570 {return true}
        return path?.unsatisfiedReason == .localNetworkDenied
    }
    /// A failure before `ready`. A TLS error is fatal even while `.waiting`: a wrong PSK shows on the client as
    /// `.waiting(-9820 bad MAC)`, never as `.failed`, and waiting would only stall.
    static func failure(_ error:NWError)->NetworkLinkFailure {if case .tls=error {return .handshakeFailed};return .unreachable}
}
