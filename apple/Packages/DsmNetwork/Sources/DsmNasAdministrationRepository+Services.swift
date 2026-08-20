import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func loadFileServiceSettings() async throws -> NasFileServiceSettings {
        let hasSMB = capabilities[DsmAPIName.coreFileServiceSMB]?.selectedVersion != nil
        let hasNFS = capabilities[DsmAPIName.coreFileServiceNFS]?.selectedVersion != nil
        let hasFTP = capabilities[DsmAPIName.coreFileServiceFTP]?.selectedVersion != nil
        let hasSFTP = capabilities[DsmAPIName.coreFileServiceSFTP]?.selectedVersion != nil
        let hasWebDiscovery = capabilities[DsmAPIName.coreWebDSM]?.selectedVersion != nil
        let hasFileDiscovery =
            capabilities[DsmAPIName.coreFileServiceDiscovery]?.selectedVersion != nil
        guard hasSMB || hasNFS || hasFTP || hasSFTP
                || hasWebDiscovery || hasFileDiscovery else {
            throw unavailableError()
        }

        let smb = hasSMB ? try await call(DsmAPIName.coreFileServiceSMB, method: "get") : nil
        let nfs = hasNFS ? try await call(DsmAPIName.coreFileServiceNFS, method: "get") : nil
        let ftp = hasFTP ? try await call(DsmAPIName.coreFileServiceFTP, method: "get") : nil
        let sftp = hasSFTP ? try await call(DsmAPIName.coreFileServiceSFTP, method: "get") : nil
        let webDiscovery = hasWebDiscovery
            ? try await call(DsmAPIName.coreWebDSM, method: "get", version: 2)
            : nil
        let fileDiscovery = hasFileDiscovery
            ? try await call(DsmAPIName.coreFileServiceDiscovery, method: "get")
            : nil

        return NasFileServiceSettings(
            isSMBEnabled: smb?.boolean(["enable_samba"]),
            isNFSEnabled: nfs?.boolean(["enable_nfs"]),
            isFTPEnabled: ftp?.boolean(["enable_ftp"]),
            isFTPSEnabled: ftp?.boolean(["enable_ftps"]),
            ftpPort: ftp?.number(["portnum"]).map(Int.init),
            isSFTPEnabled: sftp?.boolean(["enable"]),
            sftpPort: sftp?.number(["portnum", "sftp_portnum"]).map(Int.init),
            isSSDPEnabled: webDiscovery?.boolean(["enable_ssdp"]),
            isBonjourEnabled: webDiscovery?.boolean(["enable_avahi"]),
            isSMBTimeMachineEnabled: fileDiscovery?.boolean(["enable_smb_time_machine"])
        )
    }

    public func loadTerminalSettings() async throws -> NasTerminalSettings {
        let value = try await call(DsmAPIName.coreTerminal, method: "get")
        guard let ssh = value.boolean(["enable_ssh"]),
              let telnet = value.boolean(["enable_telnet"]) else {
            throw verificationError(L10n.string("shared.e53ee9190654879c"))
        }
        return NasTerminalSettings(
            isSSHEnabled: ssh,
            isTelnetEnabled: telnet,
            sshPort: value.number(["ssh_port"]).map(Int.init)
        )
    }

    public func loadProxySettings() async throws -> NasProxySettings {
        let value = try await call(DsmAPIName.coreNetworkProxy, method: "get")
        guard let enabled = value.boolean(["enable"]) else {
            throw verificationError(L10n.string("shared.21598082fdbb7d65"))
        }
        return NasProxySettings(
            isEnabled: enabled,
            host: value.string(["http_host"]) ?? "",
            port: value.number(["http_port"]).map(Int.init)
        )
    }
}
