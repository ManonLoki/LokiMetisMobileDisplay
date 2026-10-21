package com.manonloki.lokimetrisdisplay

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.Proxy
import java.net.URL

/** LAN Wi-Fi 没有互联网时也按具体路由访问桌面，不改变进程或其他请求的默认网络。 */
internal object AndroidWidgetNetwork {
    fun open(context: Context, url: URL): HttpURLConnection {
        val selected = runCatching {
            val host = url.host.removePrefix("[").removeSuffix("]").substringBefore('%')
            val address = InetAddress.getByName(host)
            val connectivity = context.getSystemService(ConnectivityManager::class.java)
            val candidates = connectivity.allNetworks.mapNotNull { network ->
                val capabilities = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
                if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                    !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) return@mapNotNull null
                val properties = connectivity.getLinkProperties(network) ?: return@mapNotNull null
                val prefix = properties.routes.filter { it.matches(address) && it.destination.prefixLength > 0 }
                    .maxOfOrNull { it.destination.prefixLength } ?: return@mapNotNull null
                network to prefix
            }
            candidates.maxByOrNull { it.second }?.first
        }.getOrNull()
        return open(url, selected)
    }

    private fun open(url: URL, network: Network?): HttpURLConnection =
        (if (network != null) network.openConnection(url, Proxy.NO_PROXY) else url.openConnection(Proxy.NO_PROXY)) as HttpURLConnection
}
