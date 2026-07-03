import Foundation
import Network

@MainActor
final class OBSBrowserSourceServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    let port: UInt16 = 8899
    private var listener: NWListener?
    private var frameProvider: (@MainActor (String?) -> DevicePreviewFrame?)?

    func start(frameProvider: @escaping @MainActor (String?) -> DevicePreviewFrame?) {
        self.frameProvider = frameProvider
        do {
            stop()
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.start(queue: DispatchQueue(label: "obsphonecam.obs.browser-source"))
            self.listener = listener
            isRunning = true
            lastError = nil
            AppLogger.shared.log(.info, .obs, "OBS browser source server started on \(port)")
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            AppLogger.shared.log(.error, .obs, "OBS browser source server failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    func viewURL(deviceID: String?) -> String {
        if let deviceID {
            return "http://127.0.0.1:\(port)/view?device=\(deviceID)"
        }
        return "http://127.0.0.1:\(port)/view"
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "obsphonecam.obs.browser-source.connection"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    AppLogger.shared.log(.error, .obs, "Browser source request failed: \(error.localizedDescription)")
                    connection.cancel()
                    return
                }
                guard let data, let request = String(data: data, encoding: .utf8) else {
                    await self.send(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad Request".utf8), on: connection)
                    return
                }
                await self.handle(request, on: connection)
            }
        }
    }

    private func handle(_ request: String, on connection: NWConnection) async {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            await send(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad Request".utf8), on: connection)
            return
        }

        let target = String(parts[1])
        if target.hasPrefix("/mjpeg") {
            await streamMJPEG(deviceID: queryValue("device", in: target), on: connection)
        } else if target.hasPrefix("/frame") {
            await sendFrame(deviceID: queryValue("device", in: target), on: connection)
        } else if target.hasPrefix("/health") {
            await sendHealth(on: connection)
        } else {
            await sendViewer(deviceID: queryValue("device", in: target), on: connection)
        }
    }

    private func sendViewer(deviceID: String?, on connection: NWConnection) async {
        let deviceQuery = deviceID.flatMap { URLQueryItem(name: "device", value: $0).encodedQuery } ?? ""
        let queryPrefix = deviceQuery.isEmpty ? "?" : "?\(deviceQuery)&"
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            html, body { margin:0; width:100%; height:100%; background:#000; overflow:hidden; }
            img { width:100vw; height:100vh; object-fit:contain; background:#000; display:block; }
            .status { position:fixed; inset:0; display:grid; place-items:center; color:#d8d8d8; font:600 28px -apple-system, BlinkMacSystemFont, sans-serif; background:#000; }
          </style>
        </head>
        <body>
          <div id="status" class="status">Esperando video de OBS Phone Cam</div>
          <img id="frame" alt="OBS Phone Cam">
          <script>
            const img = document.getElementById('frame');
            const status = document.getElementById('status');
            let sequence = 0;
            function tick() {
              const next = new Image();
              next.onload = () => {
                img.src = next.src;
                status.style.display = 'none';
                setTimeout(tick, 33);
              };
              next.onerror = () => {
                status.style.display = 'grid';
                setTimeout(tick, 250);
              };
              next.src = '/frame\(queryPrefix)t=' + Date.now() + '&n=' + sequence++;
            }
            tick();
          </script>
        </body>
        </html>
        """
        await send(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8), on: connection)
    }

    private func sendHealth(on connection: NWConnection) async {
        let hasFrame = frameProvider?(nil) != nil
        let body = """
        {"running":true,"hasFrame":\(hasFrame ? "true" : "false"),"view":"\(viewURL(deviceID: nil))"}
        """
        await send(status: "200 OK", contentType: "application/json; charset=utf-8", body: Data(body.utf8), on: connection)
    }

    private func sendFrame(deviceID: String?, on connection: NWConnection) async {
        guard let frame = frameProvider?(deviceID) else {
            await send(status: "404 Not Found", contentType: "text/plain", body: Data("No frame available".utf8), on: connection)
            return
        }
        await send(status: "200 OK", contentType: "image/jpeg", body: frame.imageData, on: connection)
    }

    private func streamMJPEG(deviceID: String?, on connection: NWConnection) async {
        let boundary = "obsphonecamframe"
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r
        Cache-Control: no-cache, no-store, must-revalidate\r
        Pragma: no-cache\r
        Connection: close\r
        \r
        """
        guard await sendRaw(Data(header.utf8), on: connection) else { return }

        var lastSequence: UInt64?
        while true {
            if let frame = frameProvider?(deviceID), frame.sequence != lastSequence {
                lastSequence = frame.sequence
                let partHeader = """
                --\(boundary)\r
                Content-Type: image/jpeg\r
                Content-Length: \(frame.imageData.count)\r
                \r
                """
                guard await sendRaw(Data(partHeader.utf8), on: connection) else { break }
                guard await sendRaw(frame.imageData, on: connection) else { break }
                guard await sendRaw(Data("\r\n".utf8), on: connection) else { break }
            }
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
        connection.cancel()
    }

    private func send(status: String, contentType: String, body: Data, on connection: NWConnection) async {
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-cache\r
        Connection: close\r
        \r
        """
        _ = await sendRaw(Data(header.utf8) + body, on: connection, isComplete: true)
    }

    private func sendRaw(_ data: Data, on connection: NWConnection, isComplete: Bool = false) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, contentContext: .defaultMessage, isComplete: isComplete, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private func queryValue(_ name: String, in target: String) -> String? {
        guard let components = URLComponents(string: target),
              let value = components.queryItems?.first(where: { $0.name == name })?.value,
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension URLQueryItem {
    var encodedQuery: String? {
        var components = URLComponents()
        components.queryItems = [self]
        return components.percentEncodedQuery
    }
}
