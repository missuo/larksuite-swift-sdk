import Foundation

/// One page of a paginated API.
public struct LarkPage<Data: Sendable>: Sendable {
    public let data: Data?
    public let hasMore: Bool
    public let nextPageToken: String?

    public init(data: Data?, hasMore: Bool, nextPageToken: String?) {
        self.data = data
        self.hasMore = hasMore
        self.nextPageToken = nextPageToken
    }
}

/// An `AsyncSequence` that walks through every page of a paginated API
/// (equivalent to the Node SDK `xxxWithIterator` helpers).
///
/// ```swift
/// for try await page in client.im.v1.message.listWithIterator(params: .init(containerIdType: "chat", containerId: chatId)) {
///     for item in page.items ?? [] { print(item.messageId ?? "") }
/// }
/// ```
public struct LarkPageSequence<Data: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Data

    let fetch: @Sendable (_ pageToken: String?) async throws -> LarkPage<Data>

    public init(fetch: @escaping @Sendable (_ pageToken: String?) async throws -> LarkPage<Data>) {
        self.fetch = fetch
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let fetch: @Sendable (String?) async throws -> LarkPage<Data>
        var pageToken: String?
        var finished = false

        public mutating func next() async throws -> Data? {
            while !finished {
                let page = try await fetch(pageToken)
                pageToken = page.nextPageToken
                if !page.hasMore || pageToken == nil || pageToken?.isEmpty == true { finished = true }
                if let d = page.data { return d }
            }
            return nil
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(fetch: fetch) }

    /// Collects all pages into an array.
    public func collect() async throws -> [Data] {
        var out: [Data] = []
        for try await p in self { out.append(p) }
        return out
    }
}

/// The query of an iterator whose method does not declare `page_token`.
///
/// node-sdk's `xxxWithIterator` helpers always send `page_token` as a query parameter, even for
/// methods whose own query has no such field; this reproduces that (`nil` is omitted).
public struct LarkPageTokenQuery: Encodable, Sendable {
    public let base: (any Encodable & Sendable)?
    public let pageToken: String?

    public init(_ base: (any Encodable & Sendable)?, pageToken: String?) {
        self.base = base
        self.pageToken = pageToken
    }

    public func encode(to encoder: any Encoder) throws {
        var object: [String: JSONValue] = [:]
        if let base, case .object(let o) = try JSONValue(data: LarkJSON.encoder.encode(base)) { object = o }
        if let pageToken { object["page_token"] = .string(pageToken) }
        try JSONValue.object(object).encode(to: encoder)
    }
}
