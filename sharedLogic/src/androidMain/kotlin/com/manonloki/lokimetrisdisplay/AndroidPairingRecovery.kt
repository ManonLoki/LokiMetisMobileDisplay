package com.manonloki.lokimetrisdisplay

import org.json.JSONObject

/** Android UI 只接触加密文件与临时恢复码；秘密仅在恢复确认后交私有存储。 */
object AndroidPairingRecovery {
    const val MAX_BYTES = PairingRecoveryCodec.MAX_BYTES
    class Exported internal constructor(val bytes: ByteArray, val recoveryCode: String) {
        override fun toString() = "AndroidPairingRecovery.Exported(redacted)"
    }
    class Payload internal constructor(internal val value: PairingRecoveryCodec.Payload) {
        val deviceId: String get() = value.deviceId
        val count: Int get() = value.materials.size
        val materials: List<JSONObject> get() = value.materials.map { JSONObject(it.fields()) }
        override fun toString() = "AndroidPairingRecovery.Payload(redacted)"
    }

    fun export(deviceId: String, materials: List<JSONObject>): Exported {
        val payload = PairingRecoveryCodec.Payload(deviceId, materials.map { material ->
            val fields = material.keys().asSequence().associateWith { material.get(it) }
            PairingRecoveryCodec.material(fields)
        })
        val result = PairingRecoveryCodec.export(payload)
        return Exported(result.bytes, result.recoveryCode)
    }

    fun open(bytes: ByteArray, recoveryCode: String): Payload = Payload(PairingRecoveryCodec.open(bytes, recoveryCode))
}
