import Foundation
import Network
import Security

public nonisolated enum CompanionTLS {
    public nonisolated struct Credential: Sendable, Equatable {
        public let identity: String
        public let key: Data

        public init(identity: String, key: Data) {
            self.identity = identity
            self.key = key
        }
    }

    public static let forwardSecretSuite: UInt16 = 0xCCAC
    private static let preferredSuites: [UInt16] = [forwardSecretSuite, 0x00A8]

    private static func dispatchData(_ data: Data) -> DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) }
    }

    private static func tlsOptions(_ credentials: [Credential]) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
        for raw: UInt16 in preferredSuites {
            guard let suite = tls_ciphersuite_t(rawValue: raw) else { preconditionFailure("PSK cipher suite unavailable") }
            sec_protocol_options_append_tls_ciphersuite(security, suite)
        }
        for credential in credentials {
            sec_protocol_options_add_pre_shared_key(
                security,
                dispatchData(credential.key) as __DispatchData,
                dispatchData(Data(credential.identity.utf8)) as __DispatchData
            )
        }
        return options
    }

    private static func parameters(_ credentials: [Credential]) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        return NWParameters(tls: tlsOptions(credentials), tcp: tcp)
    }

    public static func clientParameters(identity: String, key: Data) -> NWParameters {
        parameters([Credential(identity: identity, key: key)])
    }

    public static func serverParameters(credentials: [Credential]) -> NWParameters {
        let server = parameters(credentials)
        server.allowLocalEndpointReuse = true
        return server
    }
}
