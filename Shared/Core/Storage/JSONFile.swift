import Foundation

enum JSONCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A JSON document on disk. Reads and read-modify-write updates go through
/// `NSFileCoordinator`, so the app and its Screen Time extensions (separate
/// processes sharing an App Group container) don't clobber each other.
final class JSONFile<T: Codable> {
    private let url: URL
    private let defaultValue: T

    init(url: URL, defaultValue: T) {
        self.url = url
        self.defaultValue = defaultValue
    }

    func read() -> T {
        var result = defaultValue
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            if let data = try? Data(contentsOf: readURL),
               let value = try? JSONCoding.makeDecoder().decode(T.self, from: data) {
                result = value
            }
        }
        return result
    }

    func write(_ value: T) {
        update { $0 = value }
    }

    func update(_ body: (inout T) -> Void) {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { writeURL in
            var value = defaultValue
            if let data = try? Data(contentsOf: writeURL),
               let decoded = try? JSONCoding.makeDecoder().decode(T.self, from: data) {
                value = decoded
            }
            body(&value)
            if let data = try? JSONCoding.makeEncoder().encode(value) {
                try? data.write(to: writeURL, options: .atomic)
            }
        }
    }
}
