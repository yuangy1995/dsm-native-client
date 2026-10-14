package io.github.qwertyuiop1995.dsmnativeclient.network

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import javax.net.SocketFactory
import okhttp3.Dns
import okhttp3.OkHttpClient

/** 仅在实际路由需要局域网权限时拦截，不把公网、VPN 或本机回环当作附近设备。 */
internal class LocalNetworkAccess(context: Context) {
    private val app = context.applicationContext
    private val connectivity = app.getSystemService(ConnectivityManager::class.java)
    fun granted(): Boolean = Build.VERSION.SDK_INT < 37 ||
        app.checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED

    private fun usesLocalNetwork(): Boolean {
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork) ?: return true
        return !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
            !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
    }

    fun requiresPermission(address: InetAddress): Boolean {
        if (!usesLocalNetwork() || address.isLoopbackAddress || address.isAnyLocalAddress) return false
        if (isLocalNetworkAddress(address)) return true
        // IPv6 公网前缀也可能是当前 Wi-Fi 的直连子网。
        return address.address.size == 16 && connectivity.getLinkProperties(connectivity.activeNetwork)
            ?.routes?.any { !it.isDefaultRoute && !it.hasGateway() && it.matches(address) } == true
    }

    fun httpClient(): OkHttpClient = LocalNetworkGuard(::granted, ::requiresPermission,
        localNameNeedsPermission = ::usesLocalNetwork).applyTo(OkHttpClient.Builder())
        .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()
}

internal fun isLocalNetworkAddress(address: InetAddress): Boolean {
    if (address.isLoopbackAddress || address.isAnyLocalAddress) return false
    val bytes = address.address.map { it.toInt() and 255 }
    return if (bytes.size == 4) {
        bytes[0] == 10 || bytes[0] == 172 && bytes[1] in 16..31 ||
            bytes[0] == 192 && bytes[1] == 168 || bytes[0] == 169 && bytes[1] == 254 ||
            bytes[0] == 100 && bytes[1] in 64..127 || bytes[0] in 224..239 || bytes.all { it == 255 }
    } else address.isLinkLocalAddress || address.isSiteLocalAddress || address.isMulticastAddress ||
        bytes[0] and 0xfe == 0xfc
}

internal class LocalNetworkPermissionException : IOException("Local network access is not allowed")
internal fun localNetworkPermissionFailure() = DsmFailure(null, "Local network access is not allowed",
    "Allow nearby devices in this app's system settings and connect again.", kind = DsmErrorKind.LOCAL_NETWORK_PERMISSION_REQUIRED)

/** DNS 在解析 .local 前检查；套接字在连接前检查实际地址；复用连接在发送前再次检查。 */
internal class LocalNetworkGuard(
    private val granted: () -> Boolean,
    private val requiresPermission: (InetAddress) -> Boolean = ::isLocalNetworkAddress,
    private val localNameNeedsPermission: () -> Boolean = { true },
) {
    fun check(address: InetAddress) {
        if (!granted() && requiresPermission(address)) throw LocalNetworkPermissionException()
    }

    fun dns(delegate: Dns): Dns = object : Dns {
        override fun lookup(hostname: String): List<InetAddress> {
            if (hostname.trimEnd('.').endsWith(".local", true) && !granted() && localNameNeedsPermission()) {
                throw LocalNetworkPermissionException()
            }
            return delegate.lookup(hostname).also { addresses -> addresses.forEach(::check) }
        }
    }

    fun applyTo(builder: OkHttpClient.Builder): OkHttpClient.Builder = builder
        .dns(dns(Dns.SYSTEM))
        .socketFactory(object : SocketFactory() {
            override fun createSocket(): Socket = object : Socket() {
                override fun connect(endpoint: SocketAddress, timeout: Int) {
                    (endpoint as? InetSocketAddress)?.address?.let(::check)
                    super.connect(endpoint, timeout)
                }
            }
            override fun createSocket(host: String, port: Int): Socket = createSocket().apply { connect(InetSocketAddress(host, port)) }
            override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int): Socket =
                createSocket().apply { bind(InetSocketAddress(local, localPort)); connect(InetSocketAddress(host, port)) }
            override fun createSocket(host: InetAddress, port: Int): Socket = createSocket().apply { connect(InetSocketAddress(host, port)) }
            override fun createSocket(host: InetAddress, port: Int, local: InetAddress, localPort: Int): Socket =
                createSocket().apply { bind(InetSocketAddress(local, localPort)); connect(InetSocketAddress(host, port)) }
        })
        .addNetworkInterceptor { chain ->
            chain.connection()?.socket()?.inetAddress?.let(::check)
            chain.proceed(chain.request())
        }
}

internal fun DsmFailure.stopsConnectionFallback(): Boolean = kind in setOf(
    DsmErrorKind.LOCAL_NETWORK_PERMISSION_REQUIRED, DsmErrorKind.TLS_UNTRUSTED,
    DsmErrorKind.INSECURE_ADDRESS, DsmErrorKind.QUICK_CONNECT_IDENTITY_MISMATCH,
    DsmErrorKind.WORKSPACE_CHANGED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.PERMISSION_DENIED,
)
