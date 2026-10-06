import Foundation
import DownloaderCore

func readMessage() -> Data? {
    let stdin = FileHandle.standardInput
    let lengthData = stdin.readData(ofLength: 4)
    guard lengthData.count == 4 else { return nil }

    var length: UInt32 = 0
    _ = withUnsafeMutableBytes(of: &length) { lengthData.copyBytes(to: $0) }

    guard length > 0 && length <= 10 * 1024 * 1024 else { return nil }

    var messageData = Data()
    while messageData.count < Int(length) {
        let needed = Int(length) - messageData.count
        let chunk = stdin.readData(ofLength: needed)
        guard !chunk.isEmpty else { return nil }
        messageData.append(chunk)
    }
    return messageData
}

func writeMessage(_ data: Data) {
    let stdout = FileHandle.standardOutput
    var length = UInt32(data.count)
    let lengthData = Data(bytes: &length, count: 4)
    stdout.write(lengthData)
    stdout.write(data)
}

func run() {
    let client = UnixDomainSocketClient()

    while let messageData = readMessage() {
        do {
            let request = try JSONDecoder().decode(IPCRequest.self, from: messageData)
            let response = try client.send(request: request)
            let responseData = try JSONEncoder().encode(response)
            writeMessage(responseData)
        } catch {
            let errResponse = IPCResponse(
                success: false,
                message: "Error communicating with Internet Downloader App: \(error.localizedDescription)"
            )
            if let errData = try? JSONEncoder().encode(errResponse) {
                writeMessage(errData)
            }
        }
    }
}

run()
