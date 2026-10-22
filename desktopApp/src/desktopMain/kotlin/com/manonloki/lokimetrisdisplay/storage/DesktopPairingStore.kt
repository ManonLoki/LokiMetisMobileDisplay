package com.manonloki.lokimetrisdisplay

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.StandardOpenOption.WRITE
import java.nio.file.attribute.PosixFileAttributeView
import java.nio.file.attribute.PosixFilePermissions

/** 配对材料只进入本机用户私有文件；原子提交成功后才允许 Rust 生成确认 ACK。 */
class DesktopPairingStore(directory: Path, private val deviceId: String) {
    private val file = directory.resolve("pairings-v1.json")
    private val committed: CommittedRecords

    init {
        desktopPrivateDirectory(directory)
        require(MdnsProtocol.isCanonicalDeviceId(deviceId))
        val initial = if (!Files.exists(file, NOFOLLOW_LINKS)) emptyMap() else {
            check(Files.isRegularFile(file, NOFOLLOW_LINKS) && Files.size(file) <= MAX_BYTES)
            desktopOwnerOnly(file, false)
            val raw = Files.readAllBytes(file)
            val text = try { Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(raw)).toString() } finally { raw.fill(0) }
            TerminalJsonBoundary.validateObject(text)
            val value = JSONObject(text)
            check(value.int("version") == 1 && value.string("deviceId") == deviceId)
            val records = value.obj("records")
            check(records.length() <= 64)
            records.keys().asSequence().associateWith { id ->
                check(MdnsProtocol.isCanonicalDeviceId(id))
                records.obj(id).also { validateMaterial(id, it) }.toString()
            }
        }
        committed = CommittedRecords(initial)
    }

    fun load(clientId: String): JSONObject? {
        require(MdnsProtocol.isCanonicalDeviceId(clientId))
        return committed.snapshot()[clientId]?.let { JSONObject(it).also { value -> validateMaterial(clientId, value) } }
    }
    fun clientIds(): Set<String> = committed.snapshot().keys.toSet()
    fun save(material: JSONObject): Boolean {
        val id = material.string("clientId"); validateMaterial(id, material)
        check(id in committed.snapshot() || committed.snapshot().size < 64)
        return committed.update(id, material.toString(), ::persist)
    }
    fun forget(clientId: String): Boolean {
        require(MdnsProtocol.isCanonicalDeviceId(clientId))
        return committed.update(clientId, null, ::persist)
    }
    private fun validateMaterial(id: String, material: JSONObject) {
        check(MdnsProtocol.isCanonicalDeviceId(id) && material.string("clientId") == id && material.string("deviceId") == deviceId)
        check(material.string("secret").length in 1..1024 && material.toString().toByteArray(Charsets.UTF_8).size <= 8192)
    }
    private fun persist(records: Map<String, String>): Boolean {
        val value = JSONObject().put("version", 1).put("deviceId", deviceId)
            .put("records", JSONObject().apply { records.forEach { (id, raw) -> put(id, JSONObject(raw)) } })
        val bytes = value.toString().toByteArray(Charsets.UTF_8)
        return try { check(bytes.size <= MAX_BYTES); desktopAtomicWrite(file, bytes); true }
        catch (_: Exception) { false } finally { bytes.fill(0) }
    }
    private companion object { const val MAX_BYTES = 600_000L }
}

/** 不跟随精确数据目录或目标文件的符号链接。 */
internal fun desktopPrivateDirectory(path: Path) {
    Files.createDirectories(path)
    check(Files.isDirectory(path, NOFOLLOW_LINKS) && !Files.isSymbolicLink(path))
    desktopOwnerOnly(path, true)
}
internal fun desktopOwnerOnly(path: Path, directory: Boolean) {
    if (Files.getFileAttributeView(path, PosixFileAttributeView::class.java, NOFOLLOW_LINKS) != null) {
        Files.setPosixFilePermissions(path, PosixFilePermissions.fromString(if (directory) "rwx------" else "rw-------"))
    } else {
        // Windows 使用 ACL 将读取权限限制到本机当前用户；不以 File.setReadable 的返回值假称私密。
        Files.getFileAttributeView(path, java.nio.file.attribute.AclFileAttributeView::class.java, NOFOLLOW_LINKS)?.let { view ->
            val owner = Files.getOwner(path, NOFOLLOW_LINKS)
            view.acl = listOf(java.nio.file.attribute.AclEntry.newBuilder().setType(java.nio.file.attribute.AclEntryType.ALLOW)
                .setPrincipal(owner).setPermissions(java.nio.file.attribute.AclEntryPermission.values().toSet()).build())
        } ?: error("desktop_private_permissions_unavailable")
    }
}
internal fun desktopAtomicWrite(path: Path, bytes: ByteArray) {
    desktopPrivateDirectory(path.parent)
    check(!Files.exists(path, NOFOLLOW_LINKS) || Files.isRegularFile(path, NOFOLLOW_LINKS))
    val temporary = Files.createTempFile(path.parent, ".${path.fileName}-", ".tmp")
    try {
        desktopOwnerOnly(temporary, false)
        FileChannel.open(temporary, WRITE).use { output ->
            val buffer = ByteBuffer.wrap(bytes)
            while (buffer.hasRemaining()) output.write(buffer)
            output.force(true)
        }
        Files.move(temporary, path, ATOMIC_MOVE, REPLACE_EXISTING)
    } finally { Files.deleteIfExists(temporary) }
}
internal fun desktopValidHash(value: String): Boolean = value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
