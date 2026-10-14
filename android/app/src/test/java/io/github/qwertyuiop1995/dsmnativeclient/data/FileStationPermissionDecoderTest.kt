package io.github.qwertyuiop1995.dsmnativeclient.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

/** 使用官方 List v2 的权限结构；POSIX 模式同样返回当前登录用户的 ACL 派生结果。 */
class FileStationPermissionDecoderTest {
    @Test fun aclModeUsesReadWriteAndDelForCurrentAccount() {
        val item = decode("""{"is_acl_mode":true,"acl":{"read":true,"write":true,"del":true}}""")
        assertTrue(item.canRead); assertTrue(item.canWrite); assertTrue(item.canDelete)
    }
    @Test fun posixModeStillUsesReturnedAclRights() {
        val item = decode("""{"is_acl_mode":false,"posix":777,"acl":{"read":true,"write":true,"del":false}}""")
        assertTrue(item.canRead); assertTrue(item.canWrite); assertFalse(item.canDelete)
    }
    @Test fun explicitAclDenialCannotFallBackToSharedOrLegacyAllow() {
        val item = decode("""{"share_right":"RW","read":true,"write":true,"delete":true,"acl":{"read":false,"write":false,"del":false}}""", root = "shares")
        assertFalse(item.canRead); assertFalse(item.canWrite); assertFalse(item.canDelete)
    }
    @Test fun missingPermissionsAndPosixNumbersDoNotGrantAccess() {
        listOf("{}", "null", """{"posix":777}""", """{"acl":{}}""").forEach { permission ->
            val item = decode(permission)
            assertFalse(item.canRead); assertFalse(item.canWrite); assertFalse(item.canDelete)
        }
    }
    @Test fun sharedFolderReadWriteSummaryIsUsedWhenAclIsNotReturned() {
        val writable = decode("""{"share_right":"RW"}""", root = "shares")
        assertTrue(writable.canRead); assertTrue(writable.canWrite); assertFalse(writable.canDelete)
        val readonly = decode("""{"share_right":"RO"}""", root = "shares")
        assertTrue(readonly.canRead); assertFalse(readonly.canWrite); assertFalse(readonly.canDelete)
        assertFalse(decode("""{"share_right":"unknown"}""", root = "shares").canRead)
    }
    @Test fun explicitlyRecordedLegacyPermissionFieldsRemainCompatible() {
        val item = decode("""{"read":"1","write":"0","delete":true}""")
        assertTrue(item.canRead); assertFalse(item.canWrite); assertTrue(item.canDelete)
    }
    private fun decode(permission: String, root: String = "files") = parseFilePageFixture(Json.parseToJsonElement(
        """{"$root":[{"path":"${if (root == "shares") "/synthetic" else "/synthetic/item"}","name":"item","isdir":${root == "shares"},"additional":{"perm":$permission}}],"total":1,"offset":0}"""
    ).jsonObject, root).items.single()
}
