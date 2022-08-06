// The MIT License (MIT)
//
// Copyright (c) 2020–2022 Alexander Grebenyuk (github.com/kean).

import CoreData

public final class LoggerMessageEntity: NSManagedObject {
    @NSManaged public var createdAt: Date
    @NSManaged public var isPinned: Bool
    @NSManaged public var session: UUID
    @NSManaged public var level: Int16
    @NSManaged public var label: String
    @NSManaged public var text: String
    @NSManaged public var file: String
    @NSManaged public var function: String
    @NSManaged public var line: Int32 // Doubles as request state storage to save space
    @NSManaged public var metadata: Set<LoggerMetadataEntity>
    @NSManaged public var request: LoggerNetworkRequestEntity?
}

public final class LoggerMetadataEntity: NSManagedObject {
    @NSManaged public var key: String
    @NSManaged public var value: String
}

public final class LoggerNetworkRequestEntity: NSManagedObject {
    // Primary
    @NSManaged public var createdAt: Date
    @NSManaged public var isPinned: Bool
    @NSManaged public var session: UUID
    @NSManaged public var taskId: UUID
    @NSManaged public var rawTaskType: Int16
    @NSManaged public var message: LoggerMessageEntity?

    // MARK: Request

    @NSManaged public var url: String?
    @NSManaged public var host: String?
    @NSManaged public var httpMethod: String?

    // MARK: Response

    @NSManaged public var statusCode: Int32
    @NSManaged public var errorDomain: String?
    @NSManaged public var errorCode: Int32
#warning("TODO: rename to responseContentType")
    /// Response content-type.
    @NSManaged public var contentType: String?
    /// Returns `true` if the response was returned from the local cache.
    @NSManaged public var isFromCache: Bool

    // MARK: State

    /// Returns request state.
    public var state: LoggerNetworkRequestEntity.State {
        LoggerNetworkRequestEntity.State(rawValue: requestState) ?? .pending
    }

    /// Contains ``State-swift.enum`` raw value.
    @NSManaged var requestState: Int16
    /// Request progress.
    ///
    /// - note: The entity is created lazily when the first progress report
    /// is delivered. If no progress updates are delivered, it's never created.
    @NSManaged public var progress: LoggerNetworkRequestProgressEntity?

    // MARK: Metrics (Denormalized)

    // Timing
    /// Request start date.
    @NSManaged public var startDate: Date?
    /// Request end date.
    public var endDate: Date? {
        startDate.map { $0.addingTimeInterval(duration) }
    }
    /// Total request duration end date.
    @NSManaged public var duration: Double
    /// Number of redirects.
    @NSManaged public var redirectCount: Int16

    // MARK: Details

    #warning("TODO: should it be lazy. If yes, how to we revalidate it?")
    /// Returns decoded details.
    public lazy var details: LoggerNetworkRequestDetails? = {
        guard let compressedData = detailsData?.data,
              let data = try? (compressedData as NSData).decompressed(using: .zlib) else {
            return nil
        }
        return try? JSONDecoder().decode(LoggerNetworkRequestDetails.self, from: data as Data)
    }()

    /// Request details (encoded and compresed ``LoggerNetworkRequestDetails``).
    @NSManaged var detailsData: LoggerInlineDataEntity?

    /// The request body handle.
    @NSManaged public var requestBody: LoggerBlobHandleEntity?
    /// The response body handle.
    @NSManaged public var responseBody: LoggerBlobHandleEntity?
    /// The size of the request body.
    @NSManaged public var requestBodySize: Int64
    /// The size of the response body.
    @NSManaged public var responseBodySize: Int64

    // MARK: Helpers

    /// Returns task interval (if available from metrics).
    public var taskInterval: DateInterval? {
        guard let startDate = self.startDate, let endDate = self.endDate else {
            return nil
        }
        return DateInterval(start: startDate, end: endDate)
    }

    /// Returns task type
    public var taskType: NetworkLogger.TaskType? {
        NetworkLogger.TaskType(rawValue: rawTaskType)
    }

    public enum State: Int16 {
        case pending = 1
        case success = 2
        case failure = 3
    }
}

/// Indicates current download or upload progress.
public final class LoggerNetworkRequestProgressEntity: NSManagedObject {
    /// Indicates current download or upload progress.
    @NSManaged public var completedUnitCount: Int64
    /// Indicates current download or upload progress.
    @NSManaged public var totalUnitCount: Int64
}

/// The request details stored in a database in a denormalized format.
public final class LoggerNetworkRequestDetails: Codable, Sendable {
    public let originalRequest: NetworkLogger.Request
    public let currentRequest: NetworkLogger.Request?
    public let response: NetworkLogger.Response?
    public let error: NetworkLogger.ResponseError?
    public let metrics: NetworkLogger.Metrics?
    public let metadata: [String: String]?

    public init(originalRequest: NetworkLogger.Request, currentRequest: NetworkLogger.Request?, response: NetworkLogger.Response? = nil, error: NetworkLogger.ResponseError? = nil, metrics: NetworkLogger.Metrics? = nil, metadata: [String : String]? = nil) {
        self.originalRequest = originalRequest
        self.currentRequest = currentRequest
        self.response = response
        self.error = error
        self.metrics = metrics
        self.metadata = metadata
    }
}

/// Doesn't contain any data, just the key and some additional payload.
public final class LoggerBlobHandleEntity: NSManagedObject {
    /// A blob hash (sha1, 40 characters).
    @NSManaged public var key: String

    /// A blob size.
    @NSManaged public var size: Int64

    /// A decompressed blob size.
    @NSManaged public var decompressedSize: Int64

    /// A number of requests referencing it.
    @NSManaged var linkCount: Int16

    /// The logger inlines small blobs in a separate table in the database which
    /// significantly [reduces](https://www.sqlite.org/intern-v-extern-blob.html)
    /// the total allocated size for these files and improves the overall performance.
    ///
    /// The larger blobs are stored in an file system. And when you export a Pulse
    /// document, the larger blobs are read from the created archive on-demand,
    /// significantly reducing the speed with this the documents are opened and
    /// reducing space usage.
    ///
    /// To access data, use the convenience ``data`` property.
    @NSManaged var inlineData: LoggerInlineDataEntity?

    static let inlineLimit = 32768 // 32 KB

    /// Returns the associated data.
    ///
    /// - important: This property only works with `NSManagedObjectContext` instances
    /// created by the ``LoggerStore``. If you are reading the database manually,
    /// you'll need to access the files directly by using the associated ``key``
    /// that matches the name o the file in the `/blobs` directly in the store
    /// directory.
    public var data: Data? {
        guard let store = managedObjectContext?.userInfo[WeakLoggerStore.loggerStoreKey] as? WeakLoggerStore else {
            return nil // Should never happen unless the object was created outside of the LoggerStore moc
        }
        return store.store?.getDecompressedData(for: self)
    }
}

final class LoggerInlineDataEntity: NSManagedObject {
    @NSManaged var data: Data
}
