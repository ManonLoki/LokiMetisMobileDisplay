package com.manonloki.lokimetrisdisplay.connection

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper

/** 只比较影响局域网路由的属性；互联网验证、DNS 或信号强度变化不重置有效会话。 */
internal data class AndroidLanRoute(val interfaceName: String?, val addresses: Set<String>, val routes: Set<String>)

/** 同一网络也可能重新获取地址；失去旧网络后再次出现的相同地址仍属于新一轮连接。 */
internal class AndroidLanNetworkState<K> {
    private val routes = mutableMapOf<K, AndroidLanRoute>()
    fun updated(network: K, route: AndroidLanRoute): Boolean = routes.put(network, route) != route
    fun lost(network: K): Boolean = routes.remove(network) != null
    fun clear() = routes.clear()
}

/** 与连接活动期绑定，观察无互联网的 Wi-Fi / 以太网；默认网络切到蜂窝不代表局域网已离开。 */
internal class AndroidLanNetworkMonitor(context: Context, private val changed: () -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val connectivity = context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private val state = AndroidLanNetworkState<Network>()
    private var callback: ConnectivityManager.NetworkCallback? = null

    fun start() { main.post {
        if (callback != null) return@post
        val listener = object : ConnectivityManager.NetworkCallback() {
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                if (callback !== this) return
                if (state.updated(network, route(properties))) changed()
            }
            override fun onLost(network: Network) {
                if (callback === this && state.lost(network)) changed()
            }
        }
        callback = listener
        try {
            val request = NetworkRequest.Builder().clearCapabilities()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET).build()
            connectivity.registerNetworkCallback(request, listener, main)
            // 在回调外建立本次活动期的基线，初始通知无需再次重启刚创建的浏览。
            for (network in connectivity.allNetworks) {
                val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
                if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                    !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) continue
                connectivity.getLinkProperties(network)?.let { state.updated(network, route(it)) }
            }
        } catch (_: Exception) {
            runCatching { connectivity.unregisterNetworkCallback(listener) }
            callback = null; state.clear()
        }
    } }

    fun stop() { main.post {
        callback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        callback = null; state.clear()
    } }

    private fun route(properties: LinkProperties) = AndroidLanRoute(properties.interfaceName,
        properties.linkAddresses.map { it.toString() }.toSet(), properties.routes.map { it.toString() }.toSet())
}
