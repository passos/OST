import Foundation
import Synchronization

public enum ResumableDownloadError: Error, Sendable {
    case responseRejected
    case temporaryFileMissing
}

public protocol FileDownloading: Sendable {
    func download(
        request: URLRequest,
        destination: URL,
        resumeDataURL: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws
}

public final class ResumableFileDownloader: NSObject, FileDownloading, @unchecked Sendable {
    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private struct State {
            var continuation: CheckedContinuation<Void, Error>?
            var task: URLSessionDownloadTask?
            var session: URLSession?
            var movedFile = false
            var finished = false
        }

        private let destination: URL
        private let resumeDataURL: URL
        private let progress: @Sendable (Int64, Int64) -> Void
        private let state = Mutex(State())

        init(
            destination: URL,
            resumeDataURL: URL,
            progress: @escaping @Sendable (Int64, Int64) -> Void
        ) {
            self.destination = destination
            self.resumeDataURL = resumeDataURL
            self.progress = progress
        }

        func attach(session: URLSession, task: URLSessionDownloadTask) {
            state.withLock {
                $0.session = session
                $0.task = task
            }
        }

        func wait() async throws {
            try await withCheckedThrowingContinuation { continuation in
                let task = state.withLock { state -> URLSessionDownloadTask? in
                    state.continuation = continuation
                    return state.task
                }
                task?.resume()
            }
        }

        func cancel() {
            let task = state.withLock { $0.task }
            task?.cancel { [resumeDataURL] resumeData in
                guard let resumeData else { return }
                try? FileManager.default.createDirectory(
                    at: resumeDataURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? resumeData.write(to: resumeDataURL, options: .atomic)
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            progress(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: location, to: destination)
                state.withLock { $0.movedFile = true }
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            if let error {
                let nsError = error as NSError
                if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    try? FileManager.default.createDirectory(
                        at: resumeDataURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? resumeData.write(to: resumeDataURL, options: .atomic)
                }
                finish(.failure(error))
            } else if state.withLock({ $0.movedFile }) {
                try? FileManager.default.removeItem(at: resumeDataURL)
                finish(.success(()))
            } else {
                finish(.failure(ResumableDownloadError.temporaryFileMissing))
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            let values = state.withLock { state -> (CheckedContinuation<Void, Error>?, URLSession?) in
                guard !state.finished else { return (nil, nil) }
                state.finished = true
                let continuation = state.continuation
                state.continuation = nil
                let session = state.session
                state.session = nil
                state.task = nil
                return (continuation, session)
            }
            values.1?.finishTasksAndInvalidate()
            values.0?.resume(with: result)
        }
    }

    public func download(
        request: URLRequest,
        destination: URL,
        resumeDataURL: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let delegate = Delegate(
            destination: destination,
            resumeDataURL: resumeDataURL,
            progress: progress
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task: URLSessionDownloadTask
        if let resumeData = try? Data(contentsOf: resumeDataURL), !resumeData.isEmpty {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        delegate.attach(session: session, task: task)
        try await withTaskCancellationHandler {
            try await delegate.wait()
        } onCancel: {
            delegate.cancel()
        }
    }
}
