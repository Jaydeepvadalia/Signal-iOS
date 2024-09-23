//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalRingRTC
import XCTest

@testable import SignalServiceKit

class LocalUsernameManagerTests: XCTestCase {
    private var mockDB: MockDB!
    private var testScheduler: TestScheduler!

    private var mockReachabilityManager: MockReachabilityManager!
    private var mockStorageServiceManager: MockStorageServiceManager!
    private var mockUsernameApiClient: MockUsernameApiClient!
    private var mockUsernameLinkManager: MockUsernameLinkManager!

    private var kvStoreFactory: KeyValueStoreFactory!
    private var kvStore: KeyValueStore!

    private var localUsernameManager: LocalUsernameManager!

    override func setUp() {
        mockDB = MockDB()
        testScheduler = TestScheduler()

        mockReachabilityManager = MockReachabilityManager()
        mockStorageServiceManager = MockStorageServiceManager()
        mockUsernameApiClient = MockUsernameApiClient()
        mockUsernameLinkManager = MockUsernameLinkManager()

        kvStoreFactory = InMemoryKeyValueStoreFactory()
        kvStore = kvStoreFactory.keyValueStore(collection: "localUsernameManager")

        setLocalUsernameManager(maxNetworkRequestRetries: 0)
    }

    private func setLocalUsernameManager(maxNetworkRequestRetries: Int) {
        localUsernameManager = LocalUsernameManagerImpl(
            db: mockDB,
            kvStoreFactory: kvStoreFactory,
            reachabilityManager: mockReachabilityManager,
            schedulers: TestSchedulers(scheduler: testScheduler),
            storageServiceManager: mockStorageServiceManager,
            usernameApiClient: mockUsernameApiClient,
            usernameLinkManager: mockUsernameLinkManager,
            maxNetworkRequestRetries: maxNetworkRequestRetries
        )
    }

    override func tearDown() {
        mockUsernameApiClient.confirmationResult.ensureUnset()
        mockUsernameApiClient.deletionResult.ensureUnset()
        mockUsernameApiClient.setLinkResult.ensureUnset()
        XCTAssertNil(mockUsernameLinkManager.entropyToGenerate)
    }

    // MARK: Local state changes

    func testLocalUsernameStateChanges() {
        let linkHandle = UUID()

        XCTAssertEqual(usernameState(), .unset)

        mockDB.write { tx in
            localUsernameManager.setLocalUsername(
                username: "boba-fett",
                usernameLink: .mock(handle: linkHandle),
                tx: tx
            )
        }

        XCTAssertEqual(
            usernameState(),
            .available(username: "boba-fett", usernameLink: .mock(handle: linkHandle))
        )

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba-fett",
                tx: tx
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba-fett"))

        mockDB.write { tx in
            localUsernameManager.clearLocalUsername(tx: tx)
        }

        XCTAssertEqual(usernameState(), .unset)
    }

    func testUsernameQRCodeColorChanges() {
        func color() -> Usernames.QRCodeColor {
            return mockDB.read { tx in
                return localUsernameManager.usernameLinkQRCodeColor(tx: tx)
            }
        }

        XCTAssertEqual(color(), .unknown)

        mockDB.write { tx in
            localUsernameManager.setUsernameLinkQRCodeColor(
                color: .olive,
                tx: tx
            )
        }

        XCTAssertEqual(color(), .olive)
    }

    // MARK: Confirmation

    func testConfirmUsernameHappyPath() {
        let linkHandle = UUID()
        let username = "boba_fett.42"

        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmationResult = .value(.success(
            usernameLinkHandle: linkHandle
        ))

        XCTAssertEqual(usernameState(), .unset)

        let guarantee = mockDB.write { tx in
            localUsernameManager.confirmUsername(
                reservedUsername: .mock(username),
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(
            guarantee.value,
            .success(.success(username: username, usernameLink: .mock(handle: linkHandle)))
        )
        XCTAssertEqual(
            usernameState(),
            .available(username: username, usernameLink: .mock(handle: linkHandle))
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testConfirmBailsEarlyIfNotReachable() {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.confirmUsername(
                reservedUsername: .mock("boba_fett.43"),
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value, .failure(.networkError))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testNoCorruptionIfFailToGenerateLink() {
        mockUsernameLinkManager.entropyToGenerate = .failure(OWSGenericError("A Sarlacc"))

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.confirmUsername(
                reservedUsername: .mock("boba_fett.43"),
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value, .failure(.otherError))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testCorruptionIfNetworkErrorWhileConfirming() {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmationResult = .error(OWSHTTPError.mockNetworkFailure)

        XCTAssertEqual(usernameState(), .unset)

        let guarantee = mockDB.write { tx in
            localUsernameManager.confirmUsername(
                reservedUsername: .mock("boba_fett.42"),
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value, .failure(.networkError))
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testCorruptionIfErrorWhileConfirming() {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmationResult = .error()

        XCTAssertEqual(usernameState(), .unset)

        let guarantee = mockDB.write { tx in
            localUsernameManager.confirmUsername(
                reservedUsername: .mock("boba_fett.42"),
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value, .failure(.otherError))
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testNoCorruptionIfRejectedWhileConfirming() {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmationResult = .value(.rejected)

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.confirmUsername(
                reservedUsername: .mock("boba_fett.43"),
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value, .success(.rejected))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testNoCorruptionIfRateLimitedWhileConfirming() {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmationResult = .value(.rateLimited)

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.confirmUsername(
                reservedUsername: .mock("boba_fett.43"),
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value, .success(.rateLimited))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testSuccessfulConfirmationClearsLinkCorruption() {
        let newHandle = UUID()

        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmationResult = .value(.success(usernameLinkHandle: newHandle))

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba_fett.42",
                tx: tx
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))

        let guarantee = mockDB.write { tx in
            localUsernameManager.confirmUsername(
                reservedUsername: try! Usernames.HashedUsername(forUsername: "boba_fett.43"),
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        let expectedNewLink = Usernames.UsernameLink(handle: newHandle, entropy: .mockEntropy)!

        XCTAssertEqual(
            guarantee.value,
            .success(.success(username: "boba_fett.43", usernameLink: expectedNewLink))
        )
        XCTAssertEqual(
            usernameState(),
            .available(username: "boba_fett.43", usernameLink: expectedNewLink)
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testSuccessfulConfirmationClearsUsernameCorruption() {
        let newHandle = UUID()

        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.confirmationResult = .value(.success(usernameLinkHandle: newHandle))

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameCorrupted(tx: tx)
        }

        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)

        let guarantee = mockDB.write { tx in
            localUsernameManager.confirmUsername(
                reservedUsername: try! Usernames.HashedUsername(forUsername: "boba_fett.43"),
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        let expectedNewLink = Usernames.UsernameLink(handle: newHandle, entropy: .mockEntropy)!

        XCTAssertEqual(
            guarantee.value,
            .success(.success(username: "boba_fett.43", usernameLink: expectedNewLink))
        )
        XCTAssertEqual(
            usernameState(),
            .available(username: "boba_fett.43", usernameLink: expectedNewLink)
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    // MARK: Deletion

    func testDeletionHappyPath() {
        mockUsernameApiClient.deletionResult = .value(())

        _ = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.deleteUsername(tx: tx)
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value?.isSuccess, true)
        XCTAssertEqual(usernameState(), .unset)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testDeleteBailsEarlyIfNotReachable() {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.deleteUsername(tx: tx)
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value?.isNetworkError, true)
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testCorruptionIfNetworkErrorWhileDeleting() {
        mockUsernameApiClient.deletionResult = .error(OWSHTTPError.mockNetworkFailure)

        _ = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.deleteUsername(tx: tx)
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value?.isNetworkError, true)
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testCorruptionIfErrorWhileDeleting() {
        mockUsernameApiClient.deletionResult = .error()

        _ = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.deleteUsername(tx: tx)
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value?.isOtherError, true)
        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testDeletionClearsCorruption() {
        mockUsernameApiClient.deletionResult = .value(())

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameCorrupted(tx: tx)
        }

        XCTAssertEqual(usernameState(), .usernameAndLinkCorrupted)

        let guarantee = mockDB.write { tx in
            localUsernameManager.deleteUsername(tx: tx)
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value?.isSuccess, true)
        XCTAssertEqual(usernameState(), .unset)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testDeletionClearsLinkCorruption() {
        mockUsernameApiClient.deletionResult = .value(())

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba_fett.42",
                tx: tx
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))

        let guarantee = mockDB.write { tx in
            localUsernameManager.deleteUsername(tx: tx)
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value?.isSuccess, true)
        XCTAssertEqual(usernameState(), .unset)
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    // MARK: Rotate link

    func testRotationHappyPath() {
        let newHandle = UUID()

        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.setLinkResult = .value(newHandle)

        _ = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.rotateUsernameLink(tx: tx)
        }

        testScheduler.runUntilIdle()

        let expectedNewLink = Usernames.UsernameLink(handle: newHandle, entropy: .mockEntropy)!

        XCTAssertEqual(guarantee.value, .success(expectedNewLink))
        XCTAssertEqual(
            usernameState(),
            .available(username: "boba_fett.42", usernameLink: expectedNewLink)
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testRotationBailsEarlyIfNotReachable() {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.rotateUsernameLink(tx: tx)
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value!, .failure(.networkError))
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testNoCorruptionIfFailToGenerateNewLink() {
        mockUsernameLinkManager.entropyToGenerate = .failure(OWSGenericError("Jabba's Sudden But Inevitable Betrayal"))

        let stateBeforeRotate = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.rotateUsernameLink(tx: tx)
        }

        XCTAssertEqual(guarantee.value, .failure(.otherError))
        XCTAssertEqual(usernameState(), stateBeforeRotate)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testCorruptionIfNetworkErrorWhileRotatingLink() {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.setLinkResult = .error(OWSHTTPError.mockNetworkFailure)

        _ = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.rotateUsernameLink(tx: tx)
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value, .failure(.networkError))
        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testCorruptionIfErrorWhileRotatingLink() {
        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.setLinkResult = .error()

        _ = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.rotateUsernameLink(tx: tx)
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value, .failure(.otherError))
        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testSuccessfulRotationClearsCorruption() {
        let newHandle = UUID()

        mockUsernameLinkManager.entropyToGenerate = .success(.mockEntropy)
        mockUsernameApiClient.setLinkResult = .value(newHandle)

        mockDB.write { tx in
            localUsernameManager.setLocalUsernameWithCorruptedLink(
                username: "boba_fett.42",
                tx: tx
            )
        }

        XCTAssertEqual(usernameState(), .linkCorrupted(username: "boba_fett.42"))

        let guarantee = mockDB.write { tx in
            localUsernameManager.rotateUsernameLink(tx: tx)
        }

        testScheduler.runUntilIdle()

        let expectedNewLink = Usernames.UsernameLink(handle: newHandle, entropy: .mockEntropy)!

        XCTAssertEqual(guarantee.value, .success(expectedNewLink))
        XCTAssertEqual(
            usernameState(),
            .available(username: "boba_fett.42", usernameLink: expectedNewLink)
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testUpdateVisibleCaseHappyPath() {
        let linkHandle = UUID()

        mockUsernameApiClient.setLinkMock = { _, keepLinkHandle in
            XCTAssertTrue(keepLinkHandle)
            return .value(linkHandle)
        }

        let currentLink = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let guarantee = mockDB.write { tx in
            localUsernameManager.updateVisibleCaseOfExistingUsername(
                newUsername: "BoBa_fEtT.42",
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value?.isSuccess, true)
        XCTAssertEqual(
            usernameState(),
            .available(username: "BoBa_fEtT.42", usernameLink: currentLink)
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testUpdateVisibleCaseBailsEarlyIfNotReachable() {
        mockReachabilityManager.isReachable = false

        let stateBeforeConfirm = setUsername(username: "boba_fett.42")

        let guarantee = mockDB.write { tx in
            localUsernameManager.updateVisibleCaseOfExistingUsername(
                newUsername: "BoBa_fEtT.42",
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value?.isNetworkError, true)
        XCTAssertEqual(usernameState(), stateBeforeConfirm)
        XCTAssertFalse(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testUpdateVisibleCaseSetsLocalEvenIfNetworkError() {
        let linkHandle = UUID()

        mockUsernameApiClient.setLinkMock = { _, keepLinkHandle in
            XCTAssertTrue(keepLinkHandle)
            return Promise(error: OWSHTTPError.mockNetworkFailure)
        }

        _ = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let guarantee = mockDB.write { tx in
            localUsernameManager.updateVisibleCaseOfExistingUsername(
                newUsername: "BoBa_fEtT.42",
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value?.isNetworkError, true)
        XCTAssertEqual(
            usernameState(),
            .linkCorrupted(username: "BoBa_fEtT.42")
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    func testUpdateVisibleCaseSetsLocalEvenIfError() {
        let linkHandle = UUID()

        mockUsernameApiClient.setLinkMock = { _, keepLinkHandle in
            XCTAssertTrue(keepLinkHandle)
            return Promise(error: OWSGenericError("oopsie"))
        }

        _ = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let guarantee = mockDB.write { tx in
            localUsernameManager.updateVisibleCaseOfExistingUsername(
                newUsername: "BoBa_fEtT.42",
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(guarantee.value?.isOtherError, true)
        XCTAssertEqual(
            usernameState(),
            .linkCorrupted(username: "BoBa_fEtT.42")
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    // MARK: Network retries

    func testUpdateVisibleCaseWorkSecondTimeAfterNetworkError() {
        setLocalUsernameManager(maxNetworkRequestRetries: 1)

        var networkAttempts = 0
        let linkHandle = UUID()

        mockUsernameApiClient.setLinkMock = { _, keepLinkHandle in
            networkAttempts += 1
            XCTAssertTrue(keepLinkHandle)

            if networkAttempts == 1 {
                return Promise(error: OWSHTTPError.mockNetworkFailure)
            }

            return .value(linkHandle)
        }

        let currentLink = setUsername(username: "boba_fett.42", linkHandle: linkHandle).usernameLink!

        let guarantee = mockDB.write { tx in
            localUsernameManager.updateVisibleCaseOfExistingUsername(
                newUsername: "BoBa_fEtT.42",
                tx: tx
            )
        }

        testScheduler.runUntilIdle()

        XCTAssertEqual(networkAttempts, 2)
        XCTAssertEqual(guarantee.value?.isSuccess, true)
        XCTAssertEqual(
            usernameState(),
            .available(username: "BoBa_fEtT.42", usernameLink: currentLink)
        )
        XCTAssertTrue(mockStorageServiceManager.didRecordPendingLocalAccountUpdates)
    }

    // MARK: Utilities

    private func setUsername(
        username: String,
        linkHandle: UUID? = nil
    ) -> Usernames.LocalUsernameState {
        return mockDB.write { tx in
            localUsernameManager.setLocalUsername(
                username: username,
                usernameLink: .mock(handle: linkHandle ?? UUID()),
                tx: tx
            )

            return localUsernameManager.usernameState(tx: tx)
        }
    }

    private func usernameState() -> Usernames.LocalUsernameState {
        return mockDB.read { tx in
            return localUsernameManager.usernameState(tx: tx)
        }
    }
}

private extension Usernames.RemoteMutationResult<Void> {
    var isSuccess: Bool {
        switch self {
        case .success: return true
        case .failure: return false
        }
    }

    var isNetworkError: Bool {
        switch self {
        case .failure(.networkError): return true
        case .success, .failure(.otherError): return false
        }
    }

    var isOtherError: Bool {
        switch self {
        case .failure(.otherError): return true
        case .success, .failure(.networkError): return false
        }
    }
}

// MARK: - Mocks

private extension OWSHTTPError {
    static var mockNetworkFailure: OWSHTTPError {
        return .networkFailure(requestUrl: URL(string: "https://signal.org")!)
    }
}

private extension Usernames.HashedUsername {
    static func mock(_ username: String) -> Usernames.HashedUsername {
        try! Usernames.HashedUsername(forUsername: username)
    }
}

private extension Usernames.UsernameLink {
    static func mock(handle: UUID) -> Usernames.UsernameLink {
        Usernames.UsernameLink(
            handle: handle,
            entropy: .mockEntropy
        )!
    }
}

private extension Data {
    static let mockEntropy = Data(repeating: 12, count: 32)
}

private class MockReachabilityManager: SSKReachabilityManager {
    var isReachable: Bool = true
    func isReachable(via reachabilityType: ReachabilityType) -> Bool { owsFail("Not implemented!") }
}

private class MockStorageServiceManager: StorageServiceManager {
    var didRecordPendingLocalAccountUpdates: Bool = false

    func recordPendingLocalAccountUpdates() {
        didRecordPendingLocalAccountUpdates = true
    }

    func waitForPendingRestores() -> Promise<Void> { Promise.value(()) }
    func resetLocalData(transaction: DBWriteTransaction) { owsFail("Not implemented!") }
    func recordPendingUpdates(updatedRecipientUniqueIds: [RecipientUniqueId]) { owsFail("Not implemented!") }
    func recordPendingUpdates(updatedAddresses: [SignalServiceAddress]) { owsFail("Not implemented!") }
    func recordPendingUpdates(updatedGroupV2MasterKeys: [Data]) { owsFail("Not implemented!") }
    func recordPendingUpdates(updatedStoryDistributionListIds: [Data]) { owsFail("Not implemented!") }
    func recordPendingUpdates(callLinkRootKeys: [CallLinkRootKey]) { owsFail("Not implemented!") }
    func recordPendingUpdates(groupModel: TSGroupModel) { owsFail("Not implemented!") }
    func setLocalIdentifiers(_ localIdentifiers: LocalIdentifiersObjC) { owsFail("Not implemented!") }
    func backupPendingChanges(authedDevice: AuthedDevice) { owsFail("Not implemented!") }
    func restoreOrCreateManifestIfNecessary(authedDevice: AuthedDevice) -> Promise<Void> { owsFail("Not implemented!") }
}
