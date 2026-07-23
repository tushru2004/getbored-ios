import Foundation
import os.log
import GetBoredCore

/// Every request/response outcome below is written here before returning to
/// the caller — DiagnosticsModule ships this subsystem's OSLogStore entries
/// to the backend, so a request failure not logged here is invisible to
/// remote diagnostics.
private let logger = Logger(
    subsystem: GetBoredIdentifiers.Logging.iOSFilterApp,
    category: "APIClient"
)

/// The diagnostics-upload endpoint itself is logged at `.debug` only (never
/// `.info`/`.warning`) — logging its own traffic at a level DiagnosticsModule
/// captures would make every snapshot include the previous snapshot's upload,
/// compounding indefinitely.
private let diagnosticsUploadPath = "/api/client-events"

/// Selects the REST API backend base URL for the current build configuration.
///
/// There is no runtime toggle — the backend is baked in at compile time.
/// DEBUG builds (e.g. `make build-device`, simulator builds) talk to the
/// staging backend; RELEASE builds (App Store / TestFlight) talk to production.
enum APIEnvironment {
    #if DEBUG
    static let baseURL = URL(string: "https://dashboard.staging.getbored.online")!
    #else
    static let baseURL = URL(string: "https://dashboard.getbored.online")!
    #endif
}

/// Errors surfaced by `APIClient` to callers.
///
/// Every case maps to something a caller can act on directly — sign the user
/// out, show a paywall, show a generic error — rather than exposing raw
/// `URLSession`/HTTP detail that every call site would otherwise have to
/// re-interpret.
enum APIError: Error {
    /// No session token was stored locally, or the server rejected the
    /// stored token with 401. Either way, the caller should treat the user
    /// as signed out.
    case signedOut

    /// The server responded 402 Payment Required: the account's plan does
    /// not currently entitle it to this endpoint.
    case subscriptionRequired

    /// Any other non-2xx HTTP status. Carries the raw status code for
    /// logging/diagnostics; callers usually show a generic error.
    case server(status: Int)

    /// The request never reached the server (offline, timeout, DNS, TLS, …).
    case network(underlying: Error)

    /// The response body was 2xx but did not decode into the expected type.
    case decoding(underlying: Error)
}

/// Thin REST client wrapping `URLSession` for the GetBored backend API.
///
/// Two entry points:
///   - `send`: raw (status, Data) result — use when the caller needs the
///     status code directly, or expects no body / a non-JSON body.
///   - `sendDecoding`: `send` followed by `JSONDecoder`, for the common case
///     of a JSON response decoding into a `Decodable` model.
///
/// Threading: `completion` is invoked on whatever queue this client's
/// `URLSession` delivers its callbacks on — a private background queue, NOT
/// the main queue. Callers that touch UI or other main-thread-only state
/// MUST hop to the main queue themselves; this client never does it for them.
///
/// Usage:
///
///   APIClient.shared.send(.get, path: "/api/me") { result in
///       // runs on URLSession's background queue — hop to main if needed
///   }
///
///   APIClient.shared.sendDecoding(MeResponse.self, method: .get, path: "/api/me") { result in
///       switch result {
///       case .success(let me): ...
///       case .failure(let error): ...
///       }
///   }
final class APIClient {

    static let shared = APIClient()

    /// HTTP methods this client supports. Deliberately a closed set — every
    /// endpoint this app calls uses one of these four.
    enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    /// Per-request timeout. Short enough that a hung request doesn't leave
    /// callers (and any UI spinner bound to their completion) waiting
    /// indefinitely; long enough to tolerate a slow mobile connection.
    private static let requestTimeout: TimeInterval = 15

    private let session: URLSession

    private init() {
        logger.info("begin init")
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        session = URLSession(configuration: configuration)
        logger.info("end init: URLSession configured")
    }

    // MARK: - send

    /// Sends a request and hands back the raw HTTP status + body, mapped to
    /// `APIError` on failure.
    ///
    /// Call flow:
    ///
    ///   send(method, path, ...)
    ///           │
    ///           ├── authenticated == true
    ///           │       ├── KeychainStore.read(.sessionToken) == nil
    ///           │       │       └── completion(.failure(.signedOut))   ← NO network call
    ///           │       └── token present → will set "Authorization: Bearer <token>"
    ///           │
    ///           ├── buildRequest(...)  ← resolves URL + method + headers + body
    ///           │       └── fails only on a malformed path
    ///           │               → completion(.failure(.network(URLError(.badURL))))
    ///           │
    ///           ▼
    ///   session.dataTask(with: request) { data, response, transportError in ... }
    ///           │
    ///           ├── transportError != nil → completion(.failure(.network(transportError)))
    ///           │
    ///           ├── response is not HTTPURLResponse → completion(.failure(.network(...)))
    ///           │
    ///           └── switch on HTTP status code:
    ///                   ├── 200..<300 → completion(.success((status, data ?? Data())))
    ///                   ├── 401       → completion(.failure(.signedOut))
    ///                   ├── 402       → completion(.failure(.subscriptionRequired))
    ///                   └── other     → completion(.failure(.server(status: status)))
    func send(
        _ method: Method,
        path: String,
        query: [URLQueryItem]? = nil,
        jsonBody: Data? = nil,
        authenticated: Bool = true,
        completion: @escaping (Result<(status: Int, data: Data), APIError>) -> Void
    ) {
        Self.logStart(method: method, path: path)

        var bearerToken: String?
        if authenticated {
            guard let token = KeychainStore.read(.sessionToken) else {
                // No stored session token — treat exactly like a 401 without
                // spending a network round trip to find that out.
                Self.logFailure(method: method, path: path, error: .signedOut)
                completion(.failure(.signedOut))
                return
            }
            bearerToken = token
        }

        guard let request = buildRequest(
            method: method,
            path: path,
            query: query,
            jsonBody: jsonBody,
            bearerToken: bearerToken
        ) else {
            Self.logFailure(method: method, path: path, error: .network(underlying: URLError(.badURL)))
            completion(.failure(.network(underlying: URLError(.badURL))))
            return
        }

        session.dataTask(with: request) { data, response, transportError in
            if let transportError {
                let error = APIError.network(underlying: transportError)
                Self.logFailure(method: method, path: path, error: error)
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                let error = APIError.network(underlying: URLError(.badServerResponse))
                Self.logFailure(method: method, path: path, error: error)
                completion(.failure(error))
                return
            }

            let payload = data ?? Data()
            switch httpResponse.statusCode {
            case 200..<300:
                Self.logSuccess(method: method, path: path, status: httpResponse.statusCode)
                completion(.success((status: httpResponse.statusCode, data: payload)))
            case 401:
                Self.logFailure(method: method, path: path, error: .signedOut)
                completion(.failure(.signedOut))
            case 402:
                Self.logFailure(method: method, path: path, error: .subscriptionRequired)
                completion(.failure(.subscriptionRequired))
            default:
                let error = APIError.server(status: httpResponse.statusCode)
                Self.logFailure(method: method, path: path, error: error)
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Request/response logging

    /// `true` only for the diagnostics-upload endpoint — see `diagnosticsUploadPath`.
    private static func isDiagnosticsUpload(_ path: String) -> Bool {
        path == diagnosticsUploadPath
    }

    private static func logStart(method: Method, path: String) {
        if isDiagnosticsUpload(path) {
            logger.debug("begin send: \(method.rawValue, privacy: .public) \(path, privacy: .public)")
            return
        }
        logger.info("begin send: \(method.rawValue, privacy: .public) \(path, privacy: .public)")
    }

    private static func logSuccess(method: Method, path: String, status: Int) {
        if isDiagnosticsUpload(path) {
            logger.debug("end send: status=\(status, privacy: .public) \(method.rawValue, privacy: .public) \(path, privacy: .public)")
            return
        }
        logger.info("end send: status=\(status, privacy: .public) \(method.rawValue, privacy: .public) \(path, privacy: .public)")
    }

    private static func logFailure(method: Method, path: String, error: APIError) {
        if isDiagnosticsUpload(path) {
            switch error {
            case .signedOut:
                logger.debug("end send: signedOut for \(method.rawValue, privacy: .public) \(path, privacy: .public)")
            case .subscriptionRequired:
                logger.debug("end send: subscriptionRequired for \(method.rawValue, privacy: .public) \(path, privacy: .public)")
            case .server(let status):
                logger.debug("end send: server status=\(status, privacy: .public) for \(method.rawValue, privacy: .public) \(path, privacy: .public)")
            case .network(let underlying):
                logger.debug("end send: network failure for \(method.rawValue, privacy: .public) \(path, privacy: .public): \(underlying as NSError, privacy: .public)")
            case .decoding(let underlying):
                logger.debug("end send: decoding failure for \(method.rawValue, privacy: .public) \(path, privacy: .public): \(underlying as NSError, privacy: .public)")
            }
            return
        }

        let logLine: () -> Void
        switch error {
        case .signedOut:
            logLine = {
                logger.warning("end send: signedOut for \(method.rawValue, privacy: .public) \(path, privacy: .public)")
            }
        case .subscriptionRequired:
            logLine = {
                logger.warning("end send: subscriptionRequired for \(method.rawValue, privacy: .public) \(path, privacy: .public)")
            }
        case .server(let status):
            logLine = {
                logger.warning("end send: server status=\(status, privacy: .public) for \(method.rawValue, privacy: .public) \(path, privacy: .public)")
            }
        case .network(let underlying):
            logLine = {
                logger.warning("end send: network failure for \(method.rawValue, privacy: .public) \(path, privacy: .public): \(underlying as NSError, privacy: .public)")
            }
        case .decoding(let underlying):
            logLine = {
                logger.error("end send: decoding failure for \(method.rawValue, privacy: .public) \(path, privacy: .public): \(underlying as NSError, privacy: .public)")
            }
        }
        logLine()
    }

    // MARK: - sendDecoding

    /// `send` followed by `JSONDecoder`, for the common case of a JSON
    /// response body decoding into a `Decodable` model.
    ///
    /// Call flow:
    ///
    ///   sendDecoding(T.self, method, path, ...)
    ///           │
    ///           ▼
    ///   send(method, path, ...) { result in ... }
    ///           │
    ///           ├── .failure(let error) → completion(.failure(error))   ← passthrough, unchanged
    ///           │
    ///           └── .success((_, data))
    ///                   ├── JSONDecoder().decode(T.self, from: data) succeeds
    ///                   │       └── completion(.success(decoded))
    ///                   └── decode throws
    ///                           └── completion(.failure(.decoding(underlying: error)))
    func sendDecoding<T: Decodable>(
        _ type: T.Type,
        method: Method,
        path: String,
        query: [URLQueryItem]? = nil,
        jsonBody: Data? = nil,
        authenticated: Bool = true,
        completion: @escaping (Result<T, APIError>) -> Void
    ) {
        logger.info("begin sendDecoding: \(method.rawValue, privacy: .public) \(path, privacy: .public)")
        send(
            method,
            path: path,
            query: query,
            jsonBody: jsonBody,
            authenticated: authenticated
        ) { result in
            switch result {
            case .failure(let error):
                switch error {
                case .signedOut:
                    logger.warning("end sendDecoding: signedOut for \(path, privacy: .public)")
                case .subscriptionRequired:
                    logger.warning("end sendDecoding: subscriptionRequired for \(path, privacy: .public)")
                case .server(let status):
                    logger.warning("end sendDecoding: server status=\(status, privacy: .public) for \(path, privacy: .public)")
                case .network(let underlying):
                    logger.warning("end sendDecoding: network failure for \(path, privacy: .public): \(underlying as NSError, privacy: .public)")
                case .decoding(let underlying):
                    logger.error("end sendDecoding: decoding failure for \(path, privacy: .public): \(underlying as NSError, privacy: .public)")
                }
                completion(.failure(error))
            case .success(let response):
                do {
                    let decoded = try JSONDecoder().decode(T.self, from: response.data)
                    logger.info("end sendDecoding: decoded response for \(path, privacy: .public)")
                    completion(.success(decoded))
                } catch {
                    logger.error("end sendDecoding: decode failure for \(path, privacy: .public): \(error as NSError, privacy: .public)")
                    completion(.failure(.decoding(underlying: error)))
                }
            }
        }
    }

    // MARK: - Request building

    /// Assembles the `URLRequest` for a call: resolves `path` + `query`
    /// against `APIEnvironment.baseURL`, sets the HTTP method, and attaches
    /// headers for the JSON body / bearer token when present.
    ///
    /// Builds the URL by string concatenation (base + leading-slash-normalized
    /// path) rather than `URL.appendingPathComponent`, so the result never
    /// depends on Foundation's path-merging edge cases — every caller in this
    /// app passes an absolute path like "/api/me" or "/auth/apple".
    ///
    /// Returns `nil` only if URL construction itself fails (e.g. a malformed
    /// `path`) — `send` maps that to `.network(URLError(.badURL))`.
    ///
    /// NOTE: intentionally never sets an "X-Session-Delivery" header — that
    /// header is the web SPA's opt-in to receive the session token as an
    /// HttpOnly cookie instead of in the JSON response body. Native always
    /// wants the token in the body so it can store it in the Keychain itself.
    private func buildRequest(
        method: Method,
        path: String,
        query: [URLQueryItem]?,
        jsonBody: Data?,
        bearerToken: String?
    ) -> URLRequest? {
        let isDiagnosticsUpload = Self.isDiagnosticsUpload(path)
        if isDiagnosticsUpload {
            logger.debug("begin buildRequest: \(method.rawValue, privacy: .public) \(path, privacy: .public)")
        } else {
            logger.info("begin buildRequest: \(method.rawValue, privacy: .public) \(path, privacy: .public)")
        }

        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        guard var components = URLComponents(string: APIEnvironment.baseURL.absoluteString + normalizedPath) else {
            if isDiagnosticsUpload {
                logger.debug("end buildRequest: invalid URL components for \(path, privacy: .public)")
            } else {
                logger.error("end buildRequest: invalid URL components for \(path, privacy: .public)")
            }
            return nil
        }
        components.queryItems = query

        guard let url = components.url else {
            if isDiagnosticsUpload {
                logger.debug("end buildRequest: invalid URL for \(path, privacy: .public)")
            } else {
                logger.error("end buildRequest: invalid URL for \(path, privacy: .public)")
            }
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = jsonBody

        if jsonBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        if isDiagnosticsUpload {
            logger.debug("end buildRequest: request ready for \(path, privacy: .public)")
        } else {
            logger.info("end buildRequest: request ready for \(path, privacy: .public)")
        }
        return request
    }
}
