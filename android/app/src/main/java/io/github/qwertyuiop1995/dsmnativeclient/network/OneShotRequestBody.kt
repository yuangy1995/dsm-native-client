package io.github.qwertyuiop1995.dsmnativeclient.network

import okhttp3.RequestBody
import okio.BufferedSink

/** 表单与 multipart 均在最外层禁止重放，不能依赖子正文传播标记。 */
internal class OneShotRequestBody(internal val delegate: RequestBody) : RequestBody() {
    override fun contentType() = delegate.contentType()
    override fun contentLength() = delegate.contentLength()
    override fun isOneShot() = true
    override fun writeTo(sink: BufferedSink) = delegate.writeTo(sink)
}
