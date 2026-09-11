# Original-module SwiftData stores

V1.store and V14.store were generated from the original `Termind` app module
before extracting `TermindPersistence`. They contain only synthetic data: a
fixed-ID host group and, in V1, a legacy provider. SQLite's backup API copied
committed contents from the WAL into these self-contained fixtures.

Do not regenerate these fixtures using the extracted models: that would stop
checking compatibility across the original and framework module identities.
The source revision is recorded below.
726a2eb909adba3ced6a507c4704886f787e5f66
