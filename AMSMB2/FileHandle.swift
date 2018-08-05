//
//  FileHandle.swift
//  AMSMB2
//
//  Created by Amir Abbas Mousavian.
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//

import Foundation
import SMB2
import SMB2.Raw

typealias smb2fh = OpaquePointer

final class SMB2FileHandle {
    
    struct SeekWhence: RawRepresentable {
        var rawValue: Int32
        
        static let set     = SeekWhence(rawValue: SEEK_SET)
        static let current = SeekWhence(rawValue: SEEK_CUR)
        static let end     = SeekWhence(rawValue: SEEK_END)
    }
    
    private var context: SMB2Context
    private let handle: smb2fh
    private var isOpen: Bool
    
    convenience init(forReadingAtPath path: String, on context: SMB2Context) throws {
        try self.init(path, flags: O_RDONLY, on: context)
    }
    
    convenience init(forWritingAtPath path: String, on context: SMB2Context) throws {
        try self.init(path, flags: O_WRONLY, on: context)
    }
    
    convenience init(forCreatingAndWritingAtPath path: String, on context: SMB2Context) throws {
        try self.init(path, flags: O_WRONLY | O_CREAT | O_TRUNC, on: context)
    }
    
    convenience init(forCreatingIfNotExistsAtPath path: String, on context: SMB2Context) throws {
        try self.init(path, flags: O_WRONLY | O_CREAT | O_EXCL, on: context)
    }
    
    convenience init(forUpdatingAtPath path: String, on context: SMB2Context) throws {
        try self.init(path, flags: O_RDWR | O_APPEND, on: context)
    }
    
    init(forPipe path: String, on context: SMB2Context) throws {
        // smb2_open() sets overwrite flag, which is incompatible with pipe in mac's smbx
        
        let (_, cmddata) = try path.replacingOccurrences(of: "/", with: "\\").withCString { (path) in
            return try context.async_await_pdu(defaultError: .ENOENT) { (context, cbPtr) -> UnsafeMutablePointer<smb2_pdu>? in
                var req = smb2_create_request()
                req.requested_oplock_level = UInt8(SMB2_OPLOCK_LEVEL_NONE)
                req.impersonation_level = UInt32(SMB2_IMPERSONATION_IMPERSONATION)
                req.desired_access = UInt32(SMB2_FILE_READ_DATA | SMB2_FILE_READ_EA | SMB2_FILE_READ_ATTRIBUTES |
                    SMB2_FILE_WRITE_DATA | SMB2_FILE_WRITE_EA | SMB2_FILE_WRITE_ATTRIBUTES)
                req.share_access = UInt32(SMB2_FILE_SHARE_READ | SMB2_FILE_SHARE_WRITE)
                req.create_disposition = UInt32(SMB2_FILE_OPEN)
                req.create_options = UInt32(SMB2_FILE_NON_DIRECTORY_FILE)
                req.name = path
                let pReq = UnsafeMutablePointer<smb2_create_request>.allocate(capacity: 1)
                pReq.initialize(to: req)
                defer {
                    pReq.deinitialize(count: 1)
                    pReq.deallocate()
                }
                return smb2_cmd_create_async(context, pReq, SMB2Context.generic_handler, cbPtr)
            }
        }
        
        guard let reply = cmddata?.bindMemory(to: smb2_create_reply.self, capacity: 1) else {
            throw POSIXError(.EIO)
        }
        // smb2fh is not exported, we assume memory layout and advance to file_id field according to layout
        let smbfh_size = MemoryLayout<Int>.size * 2 /* cb, cb_data */ + Int(SMB2_FD_SIZE) + MemoryLayout<Int64>.size /* offset */
        let handle = UnsafeMutableRawPointer.allocate(byteCount: smbfh_size, alignment: MemoryLayout<Int64>.size)
        handle.initializeMemory(as: UInt8.self, repeating: 0, count: smbfh_size)
        handle.storeBytes(of: reply.pointee.file_id, toByteOffset: MemoryLayout<Int>.size * 2, as: smb2_file_id.self)
        
        self.context = context
        self.handle = OpaquePointer(handle)
        self.isOpen = true
    }
    
    private init(_ path: String, flags: Int32, on context: SMB2Context) throws {
        let (_, cmddata) = try context.async_await(defaultError: .ENOENT) { (context, cbPtr) -> Int32 in
            smb2_open_async(context, path, flags, SMB2Context.generic_handler, cbPtr)
        }
        
        guard let handle = OpaquePointer(cmddata) else {
            throw POSIXError(.ENOENT)
        }
        self.context = context
        self.handle = handle
        self.isOpen = true
    }
    
    deinit {
        if isOpen {
            _ = context.withThreadSafeContext { (context) in
                smb2_close(context, handle)
            }
        }
    }
    
    var fileId: smb2_file_id {
        return smb2_get_file_id(handle).pointee
    }
    
    func close() {
        _ = context.withThreadSafeContext { (context) in
            smb2_close(context, handle)
        }
        isOpen = false
    }
    
    func fstat() throws -> smb2_stat_64 {
        var st = smb2_stat_64()
        try context.async_await(defaultError: .EBADF) { (context, cbPtr) -> Int32 in
            smb2_fstat_async(context, handle, &st, SMB2Context.generic_handler, cbPtr)
        }
        return st
    }
    
    func ftruncate(toLength: UInt64) throws {
        try context.async_await(defaultError: .EIO) { (context, cbPtr) -> Int32 in
            smb2_ftruncate_async(context, handle, toLength, SMB2Context.generic_handler, cbPtr)
        }
    }
    
    var maxReadSize: Int {
        return Int(smb2_get_max_read_size(context.context))
    }
    
    /// This value allows softer streaming
    var optimizedReadSize: Int {
        return min(maxReadSize, 1048576)
    }
    
    @discardableResult
    func lseek(offset: Int64, whence: SeekWhence) throws -> Int64 {
        let result = smb2_lseek(context.context, handle, offset, whence.rawValue, nil)
        try POSIXError.throwIfError(Int32(exactly: result) ?? 0, description: context.error, default: .ESPIPE)
        return result
    }
    
    func read(length: Int = 0) throws -> Data {
        precondition(length <= UInt32.max, "Length bigger than UInt32.max can't be handled by libsmb2.")
        
        let count = length > 0 ? length : optimizedReadSize
        var data = Data(count: count)
        let (result, _) = try context.async_await(defaultError: .EIO) { (context, cbPtr) -> Int32 in
            data.withUnsafeMutableBytes { buffer in
                smb2_read_async(context, handle, buffer, UInt32(count), SMB2Context.generic_handler, cbPtr)
            }
        }
        data.count = Int(result)
        return data
    }
    
    func pread(offset: UInt64, length: Int = 0) throws -> Data {
        precondition(length <= UInt32.max, "Length bigger than UInt32.max can't be handled by libsmb2.")
        
        let count = length > 0 ? length : optimizedReadSize
        var data = Data(count: count)
        let (result, _) = try context.async_await(defaultError: .EIO) { (context, cbPtr) -> Int32 in
            data.withUnsafeMutableBytes { buffer in
                smb2_pread_async(context, handle, buffer, UInt32(count), offset, SMB2Context.generic_handler, cbPtr)
            }
        }
        data.count = Int(result)
        return data
    }
    
    var maxWriteSize: Int {
        return Int(smb2_get_max_write_size(context.context))
    }
    
    var optimizedWriteSize: Int {
        return min(maxWriteSize, 1048576)
    }
    
    func write(data: Data) throws -> Int {
        precondition(data.count <= Int32.max, "Data bigger than Int32.max can't be handled by libsmb2.")
        
        var data = data
        let count = data.count
        let (result, _) = try data.withUnsafeMutableBytes { (p: UnsafeMutablePointer<UInt8>) -> (result: Int32, data: UnsafeMutableRawPointer?) in
            try context.async_await(defaultError: .EBUSY) { (context, cbPtr) -> Int32 in
                smb2_write_async(context, handle, p, UInt32(count),
                                 SMB2Context.generic_handler, cbPtr)
            }
        }
        
        return Int(result)
    }
    
    func pwrite(data: Data, offset: UInt64) throws -> Int {
        precondition(data.count <= Int32.max, "Data bigger than Int32.max can't be handled by libsmb2.")
        
        var data = data
        let count = data.count
        let (result, _) = try data.withUnsafeMutableBytes { (p: UnsafeMutablePointer<UInt8>) -> (result: Int32, data: UnsafeMutableRawPointer?) in
            try context.async_await(defaultError: .EBUSY) { (context, cbPtr) -> Int32 in
                smb2_pwrite_async(context, handle, p, UInt32(count), offset,
                                 SMB2Context.generic_handler, cbPtr)
            }
        }
        
        return Int(result)
    }
    
    func fsync() throws {
        try context.async_await(defaultError: .EIO) { (context, cbPtr) -> Int32 in
            smb2_fsync_async(context, handle, SMB2Context.generic_handler, cbPtr)
        }
    }
    
    @discardableResult
    func fcntl(command: IOCtl.Command, data: Data) throws -> Data {
        var data = data
        let count = UInt32(data.count)
        var req: smb2_ioctl_request
        if count > 0 {
            req = data.withUnsafeMutableBytes {
                smb2_ioctl_request(ctl_code: command.rawValue, file_id: fileId, input_count: count, input: $0, flags: UInt32(SMB2_0_IOCTL_IS_FSCTL))
            }
        } else {
            req = smb2_ioctl_request(ctl_code: command.rawValue, file_id: fileId, input_count: 0, input: nil, flags: UInt32(SMB2_0_IOCTL_IS_FSCTL))
        }
        
        let (_, response) = try context.async_await_pdu(defaultError: .EBADRPC) { (context, cbdata) -> UnsafeMutablePointer<smb2_pdu>? in
            smb2_cmd_ioctl_async(context, &req, SMB2Context.generic_handler, cbdata)
        }
        
        guard let reply = response?.bindMemory(to: smb2_ioctl_reply.self, capacity: 1) else {
            throw POSIXError(.EBADMSG, description: "No reply from ioctl command.")
        }
        defer {
            smb2_free_data(context.context, reply.pointee.output)
        }
        
        return Data(bytes: reply.pointee.output, count: Int(reply.pointee.output_count))
    }
    
    func fcntl(command: IOCtl.Command) throws -> Void {
        try fcntl(command: command, data: Data())
    }
    
    func fcntl<T: DataRepresentable>(command: IOCtl.Command, args: T) throws -> Void {
        try fcntl(command: command, data: args.data())
    }
    
    func fcntl<R: DataInitializable>(command: IOCtl.Command) throws -> R {
        let result = try fcntl(command: command, data: Data())
        return try R(data: result)
    }
    
    func fcntl<T: DataRepresentable, R: DataInitializable>(command: IOCtl.Command, args: T) throws -> R {
        let result = try fcntl(command: command, data: args.data())
        return try R(data: result)
    }
}
