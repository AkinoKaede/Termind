#if os(macOS)
    import Darwin
    import Foundation

    public nonisolated enum PersistentStoreAccessError: Error, Equatable {
        case inUse
    }

    /// A separate, stable inode protects the whole container lifetime, including migration
    /// and sync journals. Never unlink the file: another process may already have it open.
    final class PersistentStoreLock {
        private let descriptor: Int32

        init(storeURL: URL) throws {
            let lockURL = storeURL.appendingPathExtension("lock")
            let descriptor = lockURL.path.withCString {
                open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                if code == EINTR { continue }
                close(descriptor)
                if code == EWOULDBLOCK { throw PersistentStoreAccessError.inUse }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            self.descriptor = descriptor
        }

        deinit {
            // Closing releases the kernel lock, including after a crash or forced quit.
            close(descriptor)
        }
    }
#endif
