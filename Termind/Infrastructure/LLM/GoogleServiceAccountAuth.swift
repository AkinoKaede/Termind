import Foundation
import Security

/// Signs in to Vertex AI with a service account.
///
/// Vertex does not take an API key. It takes a Google OAuth2 access token, and
/// the only way to get one without a browser is the JWT-bearer grant: build a
/// short-lived assertion, sign it RS256 with the private key from the service
/// account JSON, and trade it at Google's token endpoint. That is all this file
/// does.
///
/// An `actor` so the token cache has exactly one owner. Two conversations
/// starting at once must not each mint a token, and `AIConfigurationModel` is on the main
/// actor while this work is not.
///
/// The RS256 path was verified against `openssl dgst -verify` before any of the
/// UI was written — see `pkcs1(fromPKCS8:)` for the part that made it worth
/// checking first.
actor GoogleServiceAccountAuth {
    static let shared = GoogleServiceAccountAuth()

    /// Covers Vertex AI. Google's own client libraries request the same one.
    static let scope = "https://www.googleapis.com/auth/cloud-platform"

    /// Tokens live an hour. Refreshing five minutes early means a request never
    /// races the expiry it was issued against.
    private static let refreshMargin: TimeInterval = 300

    private struct CachedToken {
        var token: String
        var expiresAt: Date
    }

    /// Keyed by client email, so two service accounts do not share one slot.
    private var cache: [String: CachedToken] = [:]

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    /// A usable access token, minted or reused.
    func accessToken(serviceAccountJSON: String) async throws -> String {
        let credentials = try ServiceAccount(json: serviceAccountJSON)

        if let cached = cache[credentials.clientEmail],
            cached.expiresAt.timeIntervalSinceNow > Self.refreshMargin
        {
            return cached.token
        }

        let assertion = try Self.assertion(for: credentials)
        let (token, lifetime) = try await exchange(assertion, at: credentials.tokenURI)
        cache[credentials.clientEmail] = CachedToken(
            token: token,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
        return token
    }

    /// Reads `client_email` out of a pasted JSON without signing anything, so
    /// the editor can label the field the moment a file is imported.
    static func clientEmail(in serviceAccountJSON: String) -> String? {
        (try? ServiceAccount(json: serviceAccountJSON))?.clientEmail
    }

    static func projectID(in serviceAccountJSON: String) -> String? {
        (try? ServiceAccount(json: serviceAccountJSON))?.projectID
    }

    // MARK: - Token exchange

    private func exchange(_ assertion: String, at tokenURI: String) async throws -> (
        token: String, lifetime: TimeInterval
    ) {
        guard let url = URL(string: tokenURI) else { throw GoogleAuthError.badTokenURI(tokenURI) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:jwt-bearer"),
            URLQueryItem(name: "assertion", value: assertion),
        ]
        request.httpBody = body.percentEncodedQuery.map { Data($0.utf8) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw GoogleAuthError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GoogleAuthError.transport(String(localized: "The token endpoint did not answer with HTTP."))
        }

        // Google explains refusals here in a way worth passing through — it
        // distinguishes a clock skew from a disabled account from a key that
        // was revoked, and none of those are guessable from a status code.
        // The response never contains the private key, only a reason.
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONDecoder().decode(TokenErrorResponse.self, from: data))?.summary
            throw GoogleAuthError.rejected(reason ?? String(localized: "HTTP \(http.statusCode)"))
        }

        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw GoogleAuthError.malformedTokenResponse
        }
        return (token.accessToken, TimeInterval(token.expiresIn ?? 3600))
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var expiresIn: Int?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private struct TokenErrorResponse: Decodable {
        var error: String?
        var errorDescription: String?

        var summary: String? {
            switch (error, errorDescription) {
            case (let code?, let detail?): "\(code): \(detail)"
            case (let code?, nil): code
            case (nil, let detail?): detail
            case (nil, nil): nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    // MARK: - The assertion

    /// The JWT a service account presents in place of a password.
    private static func assertion(for credentials: ServiceAccount) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": credentials.clientEmail,
            "scope": scope,
            "aud": credentials.tokenURI,
            "iat": now,
            // One hour is the maximum Google accepts.
            "exp": now + 3600,
        ]

        // `.withoutEscapingSlashes` only for legibility when this is logged or
        // pasted into jwt.io while debugging — `https:\/\/` is valid JSON and
        // Google parses it either way.
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard
            let headerJSON = try? JSONSerialization.data(withJSONObject: header, options: options),
            let claimsJSON = try? JSONSerialization.data(withJSONObject: claims, options: options)
        else { throw GoogleAuthError.malformedServiceAccount }

        let signingInput = "\(headerJSON.base64URLEncoded).\(claimsJSON.base64URLEncoded)"
        let signature = try sign(Data(signingInput.utf8), pemPKCS8: credentials.privateKeyPEM)
        return "\(signingInput).\(signature.base64URLEncoded)"
    }

    private static func sign(_ message: Data, pemPKCS8: String) throws -> Data {
        guard let pkcs8 = Self.der(fromPEM: pemPKCS8) else {
            throw GoogleAuthError.malformedPrivateKey(String(localized: "not base64 PEM"))
        }
        let pkcs1 = try Self.pkcs1(fromPKCS8: [UInt8](pkcs8))

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw GoogleAuthError.malformedPrivateKey(Self.message(from: &error))
        }
        guard
            let signature = SecKeyCreateSignature(
                key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error)
        else {
            throw GoogleAuthError.signingFailed(Self.message(from: &error))
        }
        return signature as Data
    }

    private static func message(from error: inout Unmanaged<CFError>?) -> String {
        guard let taken = error?.takeRetainedValue() else { return String(localized: "unknown reason") }
        error = nil
        return CFErrorCopyDescription(taken) as String? ?? String(localized: "unknown reason")
    }

    // MARK: - PEM and DER

    private static func der(fromPEM pem: String) -> Data? {
        let body =
            pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: body)
    }

    /// The PKCS#1 `RSAPrivateKey` inside a PKCS#8 `PrivateKeyInfo`.
    ///
    /// This function is why the whole Vertex path was probed before any UI was
    /// built. `SecKeyCreateWithData` accepts **PKCS#1** for an RSA private key,
    /// and every service account JSON ships **PKCS#8**
    /// (`-----BEGIN PRIVATE KEY-----`) — hand it the outer form and it returns
    /// nil with an error that says nothing about which encoding it wanted.
    ///
    /// The structure is
    ///
    ///     SEQUENCE {
    ///       INTEGER version
    ///       SEQUENCE { OID rsaEncryption, NULL }
    ///       OCTET STRING { RSAPrivateKey }
    ///     }
    ///
    /// so this walks to the `OCTET STRING` rather than skipping the usual 26
    /// header bytes. The fixed offset happens to be right for a 2048-bit
    /// rsaEncryption key and silently wrong for anything else, which is the
    /// worst shape a shortcut can have.
    private static func pkcs1(fromPKCS8 der: [UInt8]) throws -> Data {
        var index = 0
        let outer = try readDER(der, &index)
        guard outer.tag == 0x30 else { throw GoogleAuthError.malformedPrivateKey(Self.derMismatch) }

        var inner = outer.contents.lowerBound
        let version = try readDER(der, &inner)
        guard version.tag == 0x02 else { throw GoogleAuthError.malformedPrivateKey(Self.derMismatch) }
        let algorithm = try readDER(der, &inner)
        guard algorithm.tag == 0x30 else { throw GoogleAuthError.malformedPrivateKey(Self.derMismatch) }
        let key = try readDER(der, &inner)
        guard key.tag == 0x04 else { throw GoogleAuthError.malformedPrivateKey(Self.derMismatch) }

        return Data(der[key.contents])
    }

    private static let derMismatch = String(localized: "not a PKCS#8 RSA private key")

    /// One DER element. `contents` covers the value, not the tag and length.
    private struct DERElement {
        var tag: UInt8
        var contents: Range<Int>
    }

    /// Reads one element starting at `index`, leaving `index` past all of it.
    private static func readDER(_ bytes: [UInt8], _ index: inout Int) throws -> DERElement {
        func truncated() -> GoogleAuthError {
            .malformedPrivateKey(String(localized: "the key data ends early"))
        }

        guard index < bytes.count else { throw truncated() }
        let tag = bytes[index]
        index += 1

        guard index < bytes.count else { throw truncated() }
        var length = Int(bytes[index])
        index += 1

        // Long form: the low seven bits say how many bytes the length occupies.
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4 else { throw truncated() }
            guard index + count <= bytes.count else { throw truncated() }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[index])
                index += 1
            }
        }

        guard length >= 0, index + length <= bytes.count else { throw truncated() }
        let contents = index..<(index + length)
        index += length
        return DERElement(tag: tag, contents: contents)
    }
}

// MARK: - The JSON Google hands out

/// The four fields Termind reads out of a service account key file.
///
/// Everything else in that JSON — the key id, the certificate URLs, the auth
/// provider — belongs to flows Termind does not use.
nonisolated private struct ServiceAccount {
    var clientEmail: String
    var privateKeyPEM: String
    var tokenURI: String
    var projectID: String?

    init(json: String) throws {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw GoogleAuthError.malformedServiceAccount }

        guard
            let email = object["client_email"] as? String, !email.isEmpty,
            let key = object["private_key"] as? String, !key.isEmpty
        else { throw GoogleAuthError.malformedServiceAccount }

        clientEmail = email
        privateKeyPEM = key
        let uri = object["token_uri"] as? String
        tokenURI = (uri?.isEmpty == false ? uri : nil) ?? "https://oauth2.googleapis.com/token"
        projectID = object["project_id"] as? String
    }
}

// MARK: - base64url

extension Data {
    /// JWT segments use base64url without padding.
    nonisolated fileprivate var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Errors

nonisolated enum GoogleAuthError: Error, LocalizedError, Equatable, Sendable {
    case malformedServiceAccount
    case malformedPrivateKey(String)
    case signingFailed(String)
    case badTokenURI(String)
    case rejected(String)
    case malformedTokenResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .malformedServiceAccount:
            String(localized: "That is not a service account key. It needs client_email and private_key.")
        case .malformedPrivateKey(let reason):
            String(localized: "The private key could not be read: \(reason).")
        case .signingFailed(let reason):
            String(localized: "Signing failed: \(reason).")
        case .badTokenURI(let value):
            String(localized: "\(value) is not a valid token endpoint.")
        case .rejected(let reason):
            String(localized: "Google refused the sign-in — \(reason)")
        case .malformedTokenResponse:
            String(localized: "Google answered the sign-in without a token.")
        case .transport(let message):
            message
        }
    }
}
