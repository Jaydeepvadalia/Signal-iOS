//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDBCipher
import SignalCoreKit

// NOTE: This file is generated by /Scripts/sds_codegen/sds_generate.py.
// Do not manually edit it, instead run `sds_codegen.sh`.

// MARK: - Record

public struct SignalAccountRecord: SDSRecord {
    public var tableMetadata: SDSTableMetadata {
        return SignalAccountSerializer.table
    }

    public static let databaseTableName: String = SignalAccountSerializer.table.tableName

    public var id: Int64?

    // This defines all of the columns used in the table
    // where this model (and any subclasses) are persisted.
    public let recordType: SDSRecordType
    public let uniqueId: String

    // Base class properties
    public let contact: Data?
    public let hasMultipleAccountContact: Bool
    public let multipleAccountLabelText: String
    public let recipientId: String

    public enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
        case id
        case recordType
        case uniqueId
        case contact
        case hasMultipleAccountContact
        case multipleAccountLabelText
        case recipientId
    }

    public static func columnName(_ column: SignalAccountRecord.CodingKeys, fullyQualified: Bool = false) -> String {
        return fullyQualified ? "\(databaseTableName).\(column.rawValue)" : column.rawValue
    }
}

// MARK: - StringInterpolation

public extension String.StringInterpolation {
    mutating func appendInterpolation(signalAccountColumn column: SignalAccountRecord.CodingKeys) {
        appendLiteral(SignalAccountRecord.columnName(column))
    }
    mutating func appendInterpolation(signalAccountColumnFullyQualified column: SignalAccountRecord.CodingKeys) {
        appendLiteral(SignalAccountRecord.columnName(column, fullyQualified: true))
    }
}

// MARK: - Deserialization

// TODO: Rework metadata to not include, for example, columns, column indices.
extension SignalAccount {
    // This method defines how to deserialize a model, given a
    // database row.  The recordType column is used to determine
    // the corresponding model class.
    class func fromRecord(_ record: SignalAccountRecord) throws -> SignalAccount {

        guard let recordId = record.id else {
            throw SDSError.invalidValue
        }

        switch record.recordType {
        case .signalAccount:

            let uniqueId: String = record.uniqueId
            let contactSerialized: Data? = record.contact
            let contact: Contact? = try SDSDeserialization.optionalUnarchive(contactSerialized, name: "contact")
            let hasMultipleAccountContact: Bool = record.hasMultipleAccountContact
            let multipleAccountLabelText: String = record.multipleAccountLabelText
            let recipientId: String = record.recipientId

            return SignalAccount(uniqueId: uniqueId,
                                 contact: contact,
                                 hasMultipleAccountContact: hasMultipleAccountContact,
                                 multipleAccountLabelText: multipleAccountLabelText,
                                 recipientId: recipientId)

        default:
            owsFailDebug("Unexpected record type: \(record.recordType)")
            throw SDSError.invalidValue
        }
    }
}

// MARK: - SDSModel

extension SignalAccount: SDSModel {
    public var serializer: SDSSerializer {
        // Any subclass can be cast to it's superclass,
        // so the order of this switch statement matters.
        // We need to do a "depth first" search by type.
        switch self {
        default:
            return SignalAccountSerializer(model: self)
        }
    }

    public func asRecord() throws -> SDSRecord {
        return try serializer.asRecord()
    }
}

// MARK: - Table Metadata

extension SignalAccountSerializer {

    // This defines all of the columns used in the table
    // where this model (and any subclasses) are persisted.
    static let recordTypeColumn = SDSColumnMetadata(columnName: "recordType", columnType: .int, columnIndex: 0)
    static let idColumn = SDSColumnMetadata(columnName: "id", columnType: .primaryKey, columnIndex: 1)
    static let uniqueIdColumn = SDSColumnMetadata(columnName: "uniqueId", columnType: .unicodeString, columnIndex: 2)
    // Base class properties
    static let contactColumn = SDSColumnMetadata(columnName: "contact", columnType: .blob, isOptional: true, columnIndex: 3)
    static let hasMultipleAccountContactColumn = SDSColumnMetadata(columnName: "hasMultipleAccountContact", columnType: .int, columnIndex: 4)
    static let multipleAccountLabelTextColumn = SDSColumnMetadata(columnName: "multipleAccountLabelText", columnType: .unicodeString, columnIndex: 5)
    static let recipientIdColumn = SDSColumnMetadata(columnName: "recipientId", columnType: .unicodeString, columnIndex: 6)

    // TODO: We should decide on a naming convention for
    //       tables that store models.
    public static let table = SDSTableMetadata(tableName: "model_SignalAccount", columns: [
        recordTypeColumn,
        idColumn,
        uniqueIdColumn,
        contactColumn,
        hasMultipleAccountContactColumn,
        multipleAccountLabelTextColumn,
        recipientIdColumn
        ])
}

// MARK: - Save/Remove/Update

@objc
extension SignalAccount {
    public func anyInsert(transaction: SDSAnyWriteTransaction) {
        sdsSave(saveMode: .insert, transaction: transaction)
    }

    public func anyUpdate(transaction: SDSAnyWriteTransaction) {
        sdsSave(saveMode: .update, transaction: transaction)
    }

    public func anyUpsert(transaction: SDSAnyWriteTransaction) {
        sdsSave(saveMode: .upsert, transaction: transaction)
    }

    // This method is used by "updateWith..." methods.
    //
    // This model may be updated from many threads. We don't want to save
    // our local copy (this instance) since it may be out of date.  We also
    // want to avoid re-saving a model that has been deleted.  Therefore, we
    // use "updateWith..." methods to:
    //
    // a) Update a property of this instance.
    // b) If a copy of this model exists in the database, load an up-to-date copy,
    //    and update and save that copy.
    // b) If a copy of this model _DOES NOT_ exist in the database, do _NOT_ save
    //    this local instance.
    //
    // After "updateWith...":
    //
    // a) Any copy of this model in the database will have been updated.
    // b) The local property on this instance will always have been updated.
    // c) Other properties on this instance may be out of date.
    //
    // All mutable properties of this class have been made read-only to
    // prevent accidentally modifying them directly.
    //
    // This isn't a perfect arrangement, but in practice this will prevent
    // data loss and will resolve all known issues.
    public func anyUpdate(transaction: SDSAnyWriteTransaction, block: (SignalAccount) -> Void) {
        guard let uniqueId = uniqueId else {
            owsFailDebug("Missing uniqueId.")
            return
        }

        block(self)

        guard let dbCopy = type(of: self).anyFetch(uniqueId: uniqueId,
                                                   transaction: transaction) else {
            return
        }

        block(dbCopy)

        dbCopy.anyUpdate(transaction: transaction)
    }

    public func anyRemove(transaction: SDSAnyWriteTransaction) {
        switch transaction.writeTransaction {
        case .yapWrite(let ydbTransaction):
            remove(with: ydbTransaction)
        case .grdbWrite(let grdbTransaction):
            do {
                let record = try asRecord()
                record.sdsRemove(transaction: grdbTransaction)
            } catch {
                owsFail("Remove failed: \(error)")
            }
        }
    }
}

// MARK: - SignalAccountCursor

@objc
public class SignalAccountCursor: NSObject {
    private let cursor: RecordCursor<SignalAccountRecord>?

    init(cursor: RecordCursor<SignalAccountRecord>?) {
        self.cursor = cursor
    }

    public func next() throws -> SignalAccount? {
        guard let cursor = cursor else {
            return nil
        }
        guard let record = try cursor.next() else {
            return nil
        }
        return try SignalAccount.fromRecord(record)
    }

    public func all() throws -> [SignalAccount] {
        var result = [SignalAccount]()
        while true {
            guard let model = try next() else {
                break
            }
            result.append(model)
        }
        return result
    }
}

// MARK: - Obj-C Fetch

// TODO: We may eventually want to define some combination of:
//
// * fetchCursor, fetchOne, fetchAll, etc. (ala GRDB)
// * Optional "where clause" parameters for filtering.
// * Async flavors with completions.
//
// TODO: I've defined flavors that take a read transaction.
//       Or we might take a "connection" if we end up having that class.
@objc
extension SignalAccount {
    public class func grdbFetchCursor(transaction: GRDBReadTransaction) -> SignalAccountCursor {
        let database = transaction.database
        do {
            let cursor = try SignalAccountRecord.fetchCursor(database)
            return SignalAccountCursor(cursor: cursor)
        } catch {
            owsFailDebug("Read failed: \(error)")
            return SignalAccountCursor(cursor: nil)
        }
    }

    // Fetches a single model by "unique id".
    public class func anyFetch(uniqueId: String,
                               transaction: SDSAnyReadTransaction) -> SignalAccount? {
        assert(uniqueId.count > 0)

        switch transaction.readTransaction {
        case .yapRead(let ydbTransaction):
            return SignalAccount.fetch(uniqueId: uniqueId, transaction: ydbTransaction)
        case .grdbRead(let grdbTransaction):
            let sql = "SELECT * FROM \(SignalAccountRecord.databaseTableName) WHERE \(signalAccountColumn: .uniqueId) = ?"
            return grdbFetchOne(sql: sql, arguments: [uniqueId], transaction: grdbTransaction)
        }
    }

    // Traverses all records.
    // Records are not visited in any particular order.
    // Traversal aborts if the visitor returns false.
    public class func anyVisitAll(transaction: SDSAnyReadTransaction, visitor: @escaping (SignalAccount) -> Bool) {
        switch transaction.readTransaction {
        case .yapRead(let ydbTransaction):
            SignalAccount.enumerateCollectionObjects(with: ydbTransaction) { (object, stop) in
                guard let value = object as? SignalAccount else {
                    owsFailDebug("unexpected object: \(type(of: object))")
                    return
                }
                guard visitor(value) else {
                    stop.pointee = true
                    return
                }
            }
        case .grdbRead(let grdbTransaction):
            do {
                let cursor = SignalAccount.grdbFetchCursor(transaction: grdbTransaction)
                while let value = try cursor.next() {
                    guard visitor(value) else {
                        return
                    }
                }
            } catch let error as NSError {
                owsFailDebug("Couldn't fetch models: \(error)")
            }
        }
    }

    // Does not order the results.
    public class func anyFetchAll(transaction: SDSAnyReadTransaction) -> [SignalAccount] {
        var result = [SignalAccount]()
        anyVisitAll(transaction: transaction) { (model) in
            result.append(model)
            return true
        }
        return result
    }
}

// MARK: - Swift Fetch

extension SignalAccount {
    public class func grdbFetchCursor(sql: String,
                                      arguments: [DatabaseValueConvertible]?,
                                      transaction: GRDBReadTransaction) -> SignalAccountCursor {
        var statementArguments: StatementArguments?
        if let arguments = arguments {
            guard let statementArgs = StatementArguments(arguments) else {
                owsFailDebug("Could not convert arguments.")
                return SignalAccountCursor(cursor: nil)
            }
            statementArguments = statementArgs
        }
        let database = transaction.database
        do {
            let statement: SelectStatement = try database.cachedSelectStatement(sql: sql)
            let cursor = try SignalAccountRecord.fetchCursor(statement, arguments: statementArguments)
            return SignalAccountCursor(cursor: cursor)
        } catch {
            Logger.error("sql: \(sql)")
            owsFailDebug("Read failed: \(error)")
            return SignalAccountCursor(cursor: nil)
        }
    }

    public class func grdbFetchOne(sql: String,
                                   arguments: StatementArguments,
                                   transaction: GRDBReadTransaction) -> SignalAccount? {
        assert(sql.count > 0)

        do {
            guard let record = try SignalAccountRecord.fetchOne(transaction.database, sql: sql, arguments: arguments) else {
                return nil
            }

            return try SignalAccount.fromRecord(record)
        } catch {
            owsFailDebug("error: \(error)")
            return nil
        }
    }
}

// MARK: - SDSSerializer

// The SDSSerializer protocol specifies how to insert and update the
// row that corresponds to this model.
class SignalAccountSerializer: SDSSerializer {

    private let model: SignalAccount
    public required init(model: SignalAccount) {
        self.model = model
    }

    // MARK: - Record

    func asRecord() throws -> SDSRecord {
        let id: Int64? = nil

        let recordType: SDSRecordType = .signalAccount
        guard let uniqueId: String = model.uniqueId else {
            owsFailDebug("Missing uniqueId.")
            throw SDSError.missingRequiredField
        }

        // Base class properties
        let contact: Data? = optionalArchive(model.contact)
        let hasMultipleAccountContact: Bool = model.hasMultipleAccountContact
        let multipleAccountLabelText: String = model.multipleAccountLabelText
        let recipientId: String = model.recipientId

        return SignalAccountRecord(id: id, recordType: recordType, uniqueId: uniqueId, contact: contact, hasMultipleAccountContact: hasMultipleAccountContact, multipleAccountLabelText: multipleAccountLabelText, recipientId: recipientId)
    }
}
