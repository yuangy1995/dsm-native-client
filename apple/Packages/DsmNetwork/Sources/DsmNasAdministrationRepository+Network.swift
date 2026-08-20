import DsmCore
import Foundation

extension DsmNasAdministrationRepository {
    public func loadEthernetInterfaces() async throws -> [NasEthernetInterface] {
        let list = try await call(
            DsmAPIName.coreNetworkEthernet,
            method: "list",
            version: 2
        )
        var rows = list.objects("interfaces")
        if rows.isEmpty {
            rows = list.array?.compactMap(\.object) ?? []
        }
        var result: [NasEthernetInterface] = []
        for row in rows {
            guard let id = row["ifname"]?.scalarString
                    ?? row["id"]?.scalarString,
                  id.hasPrefix("eth") else {
                continue
            }
            let detail = try await call(
                DsmAPIName.coreNetworkEthernet,
                method: "get",
                version: 1,
                parameters: ["ifname": .string(id)]
            )
            guard let item = Self.ethernetInterface(
                from: detail,
                fallback: row,
                id: id
            ) else {
                continue
            }
            result.append(item)
        }
        return result
    }
}
