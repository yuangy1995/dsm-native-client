package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import kotlinx.coroutines.CancellationException

internal data class DiscoveredConnection(
    val profile: NasProfile,
    val capabilities: Map<String, ApiCapability>,
)

enum class ConnectionStatus {
    PREPARING,
    CONNECTING_DIRECT,
    LOOKING_UP_QUICK_CONNECT,
    TRYING_LOCAL,
    TRYING_EXTERNAL,
    ESTABLISHING_RELAY,
    RESTORING_SESSION,
    AUTHENTICATING,
}

/**
 * 登录前只使用不含凭据的能力发现探测连接候选。
 * 找到可信连接后，调用方才可以提交账号、密码和验证码。
 */
internal class DsmConnectionResolver(
    private val api: DsmApiClient,
    private val quickConnect: DsmQuickConnectResolver = DsmQuickConnectResolver(),
) {
    suspend fun discover(
        profile: NasProfile,
        onStatus: (ConnectionStatus) -> Unit = {},
    ): DiscoveredConnection {
        val parsed = NasAddressParser.parse(profile.address, profile.port)
        if (parsed.kind == NasAddressKind.DIRECT) {
            onStatus(ConnectionStatus.CONNECTING_DIRECT)
            val connectionProfile = profile.copy(
                address = "https://${parsed.host}",
                port = parsed.port,
            )
            return DiscoveredConnection(connectionProfile, api.discover(connectionProfile))
        }

        onStatus(ConnectionStatus.LOOKING_UP_QUICK_CONNECT)
        val endpoints = try {
            quickConnect.resolve(parsed.host)
        } catch (error: DsmFailure) {
            if (error.kind == DsmErrorKind.QUICK_CONNECT_DIRECT_UNAVAILABLE) {
                emptyList()
            } else {
                throw error
            }
        }
        var lastDirectFailure: DsmFailure? = null
        for (endpoint in endpoints) {
            onStatus(
                if (endpoint.kind == QuickConnectEndpointKind.LOCAL) {
                    ConnectionStatus.TRYING_LOCAL
                } else {
                    ConnectionStatus.TRYING_EXTERNAL
                }
            )
            val connectionProfile = profile.copy(
                address = "https://${endpoint.host}",
                port = profile.port ?: endpoint.port,
            )
            try {
                return DiscoveredConnection(connectionProfile, api.discover(connectionProfile))
            } catch (error: CancellationException) {
                throw error
            } catch (error: DsmFailure) {
                lastDirectFailure = error
            }
        }

        onStatus(ConnectionStatus.ESTABLISHING_RELAY)
        return try {
            val relay = quickConnect.requestRelay(parsed.host)
            val connectionProfile = profile.copy(
                address = "https://${relay.host}",
                port = relay.port,
            )
            DiscoveredConnection(connectionProfile, api.discover(connectionProfile))
        } catch (error: CancellationException) {
            throw error
        } catch (error: DsmFailure) {
            throw if (error.kind == DsmErrorKind.QUICK_CONNECT_RELAY_UNAVAILABLE) {
                lastDirectFailure ?: error
            } else {
                error
            }
        }
    }
}
