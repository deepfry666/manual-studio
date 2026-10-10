import Foundation

/// 可取消的计数信号量：等名额的任务被取消时立即放弃等待（不占名额）。
public final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var limit: Int
    private var active = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextId: UInt64 = 0

    public init(_ limit: Int) { self.limit = max(1, limit) }

    public func setLimit(_ value: Int) {
        lock.lock()
        limit = max(1, value)
        let ready = drainLocked()
        lock.unlock()
        ready.forEach { $0.resume() }
    }

    public func acquire() async throws {
        let id: UInt64 = lock.withLock {
            nextId += 1
            return nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: ProviderError("请求已取消", kind: "aborted"))
                    return
                }
                if active < limit {
                    active += 1
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append((id, continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let index = waiters.firstIndex { $0.id == id }
            let waiter = index.map { waiters.remove(at: $0) }
            lock.unlock()
            waiter?.continuation.resume(throwing: ProviderError("请求已取消", kind: "aborted"))
        }
    }

    public func hasCapacity() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active < limit && waiters.isEmpty
    }

    public func release() {
        lock.lock()
        active = max(0, active - 1)
        let ready = drainLocked()
        lock.unlock()
        ready.forEach { $0.resume() }
    }

    private func drainLocked() -> [CheckedContinuation<Void, Error>] {
        var ready: [CheckedContinuation<Void, Error>] = []
        while active < limit, !waiters.isEmpty {
            active += 1
            ready.append(waiters.removeFirst().continuation)
        }
        return ready
    }

    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
}
