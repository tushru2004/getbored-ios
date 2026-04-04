import Foundation
import Network

class BlockPageServer {
    private var listener: NWListener?
    private let port: UInt16 = 8765
    private let htmlContent: String
    
    static let shared = BlockPageServer()
    
    private init() {
        // Load the blocked.html from the bundle
        if let htmlURL = Bundle.main.url(forResource: "blocked", withExtension: "html"),
           let content = try? String(contentsOf: htmlURL) {
            htmlContent = content
        } else {
            // Fallback inline HTML if bundle resource not found
            htmlContent = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
                <title>Content Blocked</title>
                <style>
                    * { margin: 0; padding: 0; box-sizing: border-box; }
                    body { font-family: -apple-system, system-ui, sans-serif; background: #f5f5f7;
                           display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 24px; }
                    .card { background: white; border-radius: 16px; padding: 48px 32px 36px;
                            max-width: 400px; width: 100%; text-align: center;
                            box-shadow: 0 2px 20px rgba(0,0,0,0.06); }
                    h1 { color: #1d1d1f; font-size: 22px; font-weight: 600; margin-bottom: 8px; }
                    p { color: #86868b; font-size: 15px; line-height: 1.5; }
                    .sub { font-size: 13px; margin-top: 4px; }
                    .icon { font-size: 48px; margin-bottom: 20px; }
                </style>
            </head>
            <body>
                <div class="card">
                    <div class="icon">\u{1F6E1}\u{FE0F}</div>
                    <h1>Content Blocked</h1>
                    <p>This website is not on your approved list.</p>
                    <p class="sub">Protected by GetBored</p>
                </div>
            </body>
            </html>
            """
        }
    }
    
    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
            
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("🌐 Block page server running on http://localhost:\(self.port)")
                case .failed(let error):
                    print("❌ Block page server failed: \(error)")
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: .global(qos: .utility))
        } catch {
            print("❌ Failed to start block page server: \(error)")
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, error == nil else { return }
            
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(self.htmlContent.utf8.count)\r
            Connection: close\r
            \r
            \(self.htmlContent)
            """
            
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
    }
    
    var localURL: String {
        return "http://localhost:\(port)"
    }
}
