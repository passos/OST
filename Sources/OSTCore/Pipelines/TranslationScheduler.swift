import Foundation

public enum TranslationUpdate: Sendable, Equatable {
    case translated(segmentID: UUID, text: String, isFinal: Bool, provider: ProviderID?)
    case failed(segmentID: UUID, isFinal: Bool, reason: String)
}

public actor TranslationScheduler {
    private struct Pending: Sendable {
        let segmentID: UUID
        let isFinal: Bool
        let task: Task<Void, Never>
    }

    public nonisolated let updates: AsyncStream<TranslationUpdate>
    private let continuation: AsyncStream<TranslationUpdate>.Continuation
    private var pending: [UUID: Pending] = [:]
    private var order: [UUID] = []

    public init() {
        let pair = AsyncStream<TranslationUpdate>.makeStream()
        updates = pair.stream
        continuation = pair.continuation
    }

    public func submit(
        _ event: TranscriptEvent,
        target: SupportedLanguage,
        primary: any TranslationProvider,
        fallback: (any TranslationProvider)? = nil
    ) {
        guard let segment = event.segment else { return }

        let staleTaskIDs = order.filter { pending[$0]?.segmentID == segment.id }
        for taskID in staleTaskIDs {
            cancel(taskID: taskID)
        }

        if segment.language == target {
            continuation.yield(.translated(
                segmentID: segment.id,
                text: segment.sourceText,
                isFinal: segment.isFinal,
                provider: nil
            ))
            return
        }

        while pending.count >= 3 {
            guard let staleID = order.first(where: { pending[$0]?.isFinal == false })
                ?? order.first else { break }
            cancel(taskID: staleID)
        }

        let taskID = UUID()
        let request = TranslationRequest(
            segmentID: segment.id,
            sourceLanguage: segment.language,
            targetLanguage: target,
            sourceText: segment.sourceText,
            isFinal: segment.isFinal
        )

        let task = Task { [weak self] in
            if !segment.isFinal {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    await self?.finish(taskID: taskID)
                    return
                }
            }
            guard !Task.isCancelled else {
                await self?.finish(taskID: taskID)
                return
            }
            do {
                let result = try await primary.translate(request)
                guard !Task.isCancelled else {
                    await self?.finish(taskID: taskID)
                    return
                }
                await self?.publish(
                    .translated(
                        segmentID: segment.id,
                        text: result.translatedText,
                        isFinal: segment.isFinal,
                        provider: result.provider
                    ),
                    taskID: taskID
                )
            } catch is CancellationError {
                await self?.finish(taskID: taskID)
            } catch {
                if let fallback {
                    do {
                        let result = try await fallback.translate(request)
                        await self?.publish(
                            .translated(
                                segmentID: segment.id,
                                text: result.translatedText,
                                isFinal: segment.isFinal,
                                provider: result.provider
                            ),
                            taskID: taskID
                        )
                        return
                    } catch {
                        // Report only a localized failure category; never include source text.
                    }
                }
                await self?.publish(
                    .failed(
                        segmentID: segment.id,
                        isFinal: segment.isFinal,
                        reason: "번역을 완료하지 못했습니다."
                    ),
                    taskID: taskID
                )
            }
        }

        pending[taskID] = Pending(
            segmentID: segment.id,
            isFinal: segment.isFinal,
            task: task
        )
        order.append(taskID)
    }

    public func cancelAll() async {
        for item in pending.values { item.task.cancel() }
        pending.removeAll()
        order.removeAll()
    }

    private func publish(_ update: TranslationUpdate, taskID: UUID) {
        guard pending[taskID] != nil else { return }
        continuation.yield(update)
        finish(taskID: taskID)
    }

    private func finish(taskID: UUID) {
        guard pending.removeValue(forKey: taskID) != nil else { return }
        order.removeAll { $0 == taskID }
    }

    private func cancel(taskID: UUID) {
        pending[taskID]?.task.cancel()
        finish(taskID: taskID)
    }
}
