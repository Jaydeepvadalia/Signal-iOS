//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

final class MessageBackupSessionSwitchoverChatUpdateArchiver {
    typealias Details = MessageBackup.InteractionArchiveDetails
    typealias ArchiveChatUpdateMessageResult = MessageBackup.ArchiveInteractionResult<Details>
    typealias RestoreChatUpdateMessageResult = MessageBackup.RestoreInteractionResult<Void>

    private typealias ArchiveFrameError = MessageBackup.ArchiveFrameError<MessageBackup.InteractionUniqueId>
    private typealias RestoreFrameError = MessageBackup.RestoreFrameError<MessageBackup.ChatItemId>

    private let interactionStore: any InteractionStore

    init(interactionStore: any InteractionStore) {
        self.interactionStore = interactionStore
    }

    // MARK: -

    func archive(
        infoMessage: TSInfoMessage,
        thread: TSThread,
        context: MessageBackup.ChatArchivingContext,
        tx: any DBReadTransaction
    ) -> ArchiveChatUpdateMessageResult {
        func messageFailure(
            _ errorType: ArchiveFrameError.ErrorType,
            line: UInt = #line
        ) -> ArchiveChatUpdateMessageResult {
            return .messageFailure([.archiveFrameError(
                errorType,
                infoMessage.uniqueInteractionId,
                line: line
            )])
        }

        guard
            let sessionSwitchoverPhoneNumberString = infoMessage.sessionSwitchoverPhoneNumber,
            let sessionSwitchoverPhoneNumber = E164(sessionSwitchoverPhoneNumberString)
        else {
            return .skippableChatUpdate(.legacyInfoMessage(.sessionSwitchoverWithoutPhoneNumber))
        }

        guard let switchedOverContactAddress = (thread as? TSContactThread)?.contactAddress.asSingleServiceIdBackupAddress() else {
            return messageFailure(.sessionSwitchoverUpdateMissingAuthor)
        }

        guard let threadRecipientId = context.recipientContext[.contact(switchedOverContactAddress)] else {
            return messageFailure(.referencedRecipientIdMissing(.contact(switchedOverContactAddress)))
        }

        var chatUpdateMessage = BackupProto.ChatUpdateMessage()
        chatUpdateMessage.update = .sessionSwitchover(BackupProto.SessionSwitchoverChatUpdate(
            e164: sessionSwitchoverPhoneNumber.uint64Value
        ))

        let interactionArchiveDetails = Details(
            author: threadRecipientId,
            directionalDetails: .directionless(BackupProto.ChatItem.DirectionlessMessageDetails()),
            expireStartDate: nil,
            expiresInMs: nil,
            isSealedSender: false,
            chatItemType: .updateMessage(chatUpdateMessage)
        )

        return .success(interactionArchiveDetails)
    }

    // MARK: -

    func restoreSessionSwitchoverChatUpdate(
        _ sessionSwitchoverUpdateProto: BackupProto.SessionSwitchoverChatUpdate,
        chatItem: BackupProto.ChatItem,
        chatThread: MessageBackup.ChatThread,
        context: MessageBackup.ChatRestoringContext,
        tx: any DBWriteTransaction
    ) -> RestoreChatUpdateMessageResult {
        func invalidProtoData(
            _ error: RestoreFrameError.ErrorType.InvalidProtoDataError,
            line: UInt = #line
        ) -> RestoreChatUpdateMessageResult {
            return .messageFailure([.restoreFrameError(
                .invalidProtoData(error),
                chatItem.id,
                line: line
            )])
        }

        guard let e164 = E164(sessionSwitchoverUpdateProto.e164) else {
            return invalidProtoData(.invalidE164(protoClass: BackupProto.SessionSwitchoverChatUpdate.self))
        }

        guard case .contact(let switchedOverContactThread) = chatThread else {
            return invalidProtoData(.sessionSwitchoverUpdateNotFromContact)
        }

        let sessionSwitchoverInfoMessage: TSInfoMessage = .makeForSessionSwitchover(
            contactThread: switchedOverContactThread,
            phoneNumber: e164.stringValue
        )
        interactionStore.insertInteraction(sessionSwitchoverInfoMessage, tx: tx)

        return .success(())
    }
}