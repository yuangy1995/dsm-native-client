import Foundation

/// 媒体预览的重定向必须和原始 HTTPS origin 完全一致，避免播放器请求把认证头带到其他端点。
enum MediaStreamRedirectPolicy {
    private static let sensitiveQueryNames: Set<String> = [
        "_sid", "sid", "synotoken", "syno_token", "token", "cookie", "did",
    ]
    private static let credentialHeaderNames = [
        "Cookie", "X-SYNO-TOKEN", "Authorization",
    ]

    static func redirectedRequest(
        from source: URLRequest,
        proposedRequest: URLRequest
    ) -> URLRequest? {
        guard let sourceURL = source.url,
              let destinationURL = proposedRequest.url,
              isSameHTTPSOrigin(sourceURL, destinationURL) else {
            return nil
        }
        var request = proposedRequest
        request.url = redactedURL(destinationURL)
        for header in credentialHeaderNames {
            request.setValue(
                source.value(forHTTPHeaderField: header),
                forHTTPHeaderField: header
            )
        }
        return request
    }

    private static func redactedURL(_ url: URL) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url
        }
        components.queryItems = components.queryItems?.filter {
            !sensitiveQueryNames.contains($0.name.lowercased())
        }
        return components.url ?? url
    }

    private static func isSameHTTPSOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == "https"
            && rhs.scheme?.lowercased() == "https"
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : nil)
    }
}
