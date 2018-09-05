//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import AVFoundation

public enum OWSThumbnailError: Error {
    case failure(description: String)
}

@objc public class OWSLoadedThumbnail: NSObject {
    public typealias DataSourceBlock = () throws -> Data

    @objc public let image: UIImage
    let dataSourceBlock: DataSourceBlock

    @objc public init(image: UIImage, filePath: String) {
        self.image = image
        self.dataSourceBlock = {
            return try Data(contentsOf: URL(fileURLWithPath: filePath))
        }
    }

    @objc public init(image: UIImage, data: Data) {
        self.image = image
        self.dataSourceBlock = {
            return data
        }
    }

    @objc public func data() throws -> Data {
        return try dataSourceBlock()
    }
}

private struct OWSThumbnailRequest {
    public typealias SuccessBlock = (OWSLoadedThumbnail) -> Void
    public typealias FailureBlock = () -> Void

    let attachment: TSAttachmentStream
    let thumbnailDimensionPoints: UInt
    let success: SuccessBlock
    let failure: FailureBlock

    init(attachment: TSAttachmentStream, thumbnailDimensionPoints: UInt, success: @escaping SuccessBlock, failure: @escaping FailureBlock) {
        self.attachment = attachment
        self.thumbnailDimensionPoints = thumbnailDimensionPoints
        self.success = success
        self.failure = failure
    }
}

@objc public class OWSThumbnailService: NSObject {

    // MARK: - Singleton class

    @objc(shared)
    public static let shared = OWSThumbnailService()

    public typealias SuccessBlock = (OWSLoadedThumbnail) -> Void
    public typealias FailureBlock = () -> Void

    private let serialQueue = DispatchQueue(label: "OWSThumbnailService")

    private let dbConnection: YapDatabaseConnection

    // This property should only be accessed on the serialQueue.
    //
    // We want to process requests in _reverse_ order in which they
    // arrive so that we prioritize the most recent view state.
    private var thumbnailRequestStack = [OWSThumbnailRequest]()

    private override init() {

        dbConnection = OWSPrimaryStorage.shared().newDatabaseConnection()

        super.init()

        SwiftSingletons.register(self)
    }

    private func canThumbnailAttachment(attachment: TSAttachmentStream) -> Bool {
        return attachment.isImage || attachment.isAnimated || attachment.isVideo
    }

    // completion will only be called on success.
    // completion will be called async on the main thread.
    @objc public func ensureThumbnail(forAttachment attachment: TSAttachmentStream,
                                                     thumbnailDimensionPoints: UInt,
                                                     success: @escaping SuccessBlock,
                                                     failure: @escaping FailureBlock) {
        serialQueue.async {
            let thumbnailRequest = OWSThumbnailRequest(attachment: attachment, thumbnailDimensionPoints: thumbnailDimensionPoints, success: success, failure: failure)
            self.thumbnailRequestStack.append(thumbnailRequest)

            self.processNextRequestSync()
        }
    }

    private func processNextRequestAsync() {
        serialQueue.async {
            self.processNextRequestSync()
        }
    }

    // This should only be called on the serialQueue.
    private func processNextRequestSync() {
        guard !thumbnailRequestStack.isEmpty else {
            return
        }
        let thumbnailRequest = thumbnailRequestStack.removeLast()

        do {
            let loadedThumbnail = try process(thumbnailRequest: thumbnailRequest)
            DispatchQueue.main.async {
                thumbnailRequest.success(loadedThumbnail)
            }
        } catch {
            Logger.error("Could not create thumbnail: \(error)")

            DispatchQueue.main.async {
                thumbnailRequest.failure()
            }
        }
    }

    // This should only be called on the serialQueue.
    //
    // It should be safe to assume that an attachment will never end up with two thumbnails of
    // the same size since:
    //
    // * Thumbnails are only added by this method.
    // * This method checks for an existing thumbnail using the same connection.
    // * This method is performed on the serial queue.
    private func process(thumbnailRequest: OWSThumbnailRequest) throws -> OWSLoadedThumbnail {
        let attachment = thumbnailRequest.attachment
        guard canThumbnailAttachment(attachment: attachment) else {
            throw OWSThumbnailError.failure(description: "Cannot thumbnail attachment.")
        }
        let thumbnailPath = attachment.path(forThumbnailDimensionPoints: thumbnailRequest.thumbnailDimensionPoints)
        if FileManager.default.fileExists(atPath: thumbnailPath) {
            guard let image = UIImage(contentsOfFile: thumbnailPath) else {
                throw OWSThumbnailError.failure(description: "Could not load thumbnail.")
            }
            return OWSLoadedThumbnail(image: image, filePath: thumbnailPath)
        }
        let thumbnailDirPath = (thumbnailPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: thumbnailDirPath) {
            try FileManager.default.createDirectory(atPath: thumbnailDirPath, withIntermediateDirectories: true, attributes: nil)
        }
        guard let originalFilePath = attachment.originalFilePath else {
            throw OWSThumbnailError.failure(description: "Missing original file path.")
        }
        let maxDimension = CGFloat(thumbnailRequest.thumbnailDimensionPoints)
        let thumbnailImage: UIImage
        if attachment.isImage || attachment.isAnimated {
            thumbnailImage = try OWSMediaUtils.thumbnail(forImageAtPath: originalFilePath, maxDimension: maxDimension)
        } else if attachment.isVideo {
            let maxSize = CGSize(width: maxDimension, height: maxDimension)
            thumbnailImage = try OWSMediaUtils.thumbnail(forVideoAtPath: originalFilePath, maxSize: maxSize)
        } else {
            throw OWSThumbnailError.failure(description: "Invalid attachment type.")
        }
        guard let thumbnailData = UIImageJPEGRepresentation(thumbnailImage, 0.85) else {
            throw OWSThumbnailError.failure(description: "Could not convert thumbnail to JPEG.")
        }
        do {
            try thumbnailData.write(to: NSURL.fileURL(withPath: thumbnailPath), options: .atomicWrite)
        } catch let error as NSError {
            throw OWSThumbnailError.failure(description: "File write failed: \(thumbnailPath), \(error)")
        }
        return OWSLoadedThumbnail(image: thumbnailImage, data: thumbnailData)
    }
}
