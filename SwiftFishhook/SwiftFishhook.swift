//
//  SwiftFishhook.swift
//  SwiftFishhook
//
//  Created by xurunkang on 2020/2/1.
//  Copyright © 2020 xurunkang. All rights reserved.
//

import Foundation
import MachO

typealias RebindingType = [String: Rebinding]

struct Rebinding {
    let replacement: uint_t
    let replaced: UnsafeMutablePointer<uint_t>
}

#if arch(x86_64) || arch(arm64)
let LC_SEGMENT_T = LC_SEGMENT_64

typealias uint_t = UInt64

private typealias mach_header_t = mach_header_64
private typealias nlist_t = nlist_64
private typealias section_t = section_64
private typealias segment_command_t = segment_command_64

#else
let LC_SEGMENT_T = LC_SEGMENT

typealias uint_t = UInt32

private typealias mach_header_t = mach_header
private typealias nlist_t = nlist
private typealias section_t = section
private typealias segment_command_t = segment_commands
#endif

private let SEG_DATA_CONST  = "__DATA_CONST"
private let LAZY_SYMBOL_PTR = "__la_symbol_ptr"
private let DYSYMTAB_ADDRESS_LENGTH: uint_t = 0x8

private var rebindings: RebindingType = [:]

func rebindingFunc(_ rs: RebindingType) {

    rebindings = rs

    _dyld_register_func_for_add_image { (mach_header_ptr, slide) in
        let mhp = unsafeBitCast(mach_header_ptr, to: UnsafePointer<mach_header_t>.self)
        _rebindingFunc(mhp, slide)
    }
}

private func _rebindingFunc(_ mhp: UnsafePointer<mach_header_t>, _ slide: Int) {

    let tables = getTables(mhp, slide)

    guard let symbolTable = tables.0 else { return }
    guard let stringTable = tables.1 else { return }
    guard let indirectSymbolTable = tables.2 else { return }

    // Lazy Symbol Pointer Section Header
    // Section Header(__la_symbol_ptr)
    guard let lazySymbolSection = getLazySymbolSection(mhp) else { return }

    // Lazy Symbol Pointer Table
    // Section (__DATA, __la_symbol_ptr)
    guard let lazySymbolPointers = getLazySymbolPointers(lazySymbolSection.addr, slide) else { return }

    // Index In Indirect Symbol Table
    // Dynamic Symbol Table + __la_symbol_ptr reserved1(offset)
    let lazySymbolPointerIndices = indirectSymbolTable.advanced(by: lazySymbolSection.reserved1.intValue)

    let count = lazySymbolSection.size / DYSYMTAB_ADDRESS_LENGTH

    for i in 0..<count.intValue {
        // 获取对应的 Symbol Table Index
        let symtabIndex = lazySymbolPointerIndices.advanced(by: i).pointee.intValue
        // 根据 index 获取对应函数在 String Table 中的函数名偏移量
        let strtabOffset = symbolTable.advanced(by: symtabIndex).pointee.n_un.n_strx.intValue
        // 获取函数名
        let symbolName = String(cString: stringTable.advanced(by: strtabOffset + 1))
        // 匹配函数名称, 进行替换
        if let r = rebindings[symbolName] {
            r.replaced.pointee = lazySymbolPointers.advanced(by: i).pointee
            lazySymbolPointers.advanced(by: i).pointee = r.replacement
        }
    }
}


private func getLazySymbolSection(_ mhp: UnsafePointer<mach_header_t>) -> section_t? {
    if let section = _getsectbynamefromheader(mhp, SEG_DATA, LAZY_SYMBOL_PTR)?.pointee {
        return section
    } else if let section = _getsectbynamefromheader(mhp, SEG_DATA_CONST, LAZY_SYMBOL_PTR)?.pointee {
        return section
    }

    return nil
}

private func getLazySymbolPointers(_ addr: uint_t, _ slide: Int) -> UnsafeMutablePointer<uint_t>? {
    return UnsafeMutablePointer<uint_t>(bitPattern: Int(addr) + slide)
}

private func getTables(_ mhp: UnsafePointer<mach_header_t>, _ slide: Int) -> (UnsafePointer<nlist_t>?, UnsafePointer<CChar>?, UnsafePointer<UInt32>?) {

    // 跳过 mach_header_t 段
    var cur = UnsafeRawPointer(mhp.advanced(by: 1))

    // 获取 LinkEdit 基址 - 因为 Symbol Table、Indirect Symbol Table 和 String Table 的偏移量是相对 LinkEdit 基址的
    var linkEditBaseAddress: Int?

    var symtab_cmd: symtab_command?
    var dysymtab_cmd: dysymtab_command?

    // 遍历 Load Commands
    let ncmds = mhp.pointee.ncmds
    for _ in 0..<ncmds {
        let loadCommand = cur.assumingMemoryBound(to: load_command.self).pointee

        // 获取 LC_SYMTAB - Symbol Table + String Table
        if loadCommand.cmd == LC_SYMTAB
        {
            symtab_cmd = cur.assumingMemoryBound(to: symtab_command.self).pointee
        }
        // 获取 LC_DYSMTAB - Indirect Symbols
        else if loadCommand.cmd == LC_DYSYMTAB
        {
            dysymtab_cmd = cur.assumingMemoryBound(to: dysymtab_command.self).pointee
        }
        // 获取 __LINKEDIT
        else if loadCommand.cmd == LC_SEGMENT_T
        {
            let seg_cmd = cur.assumingMemoryBound(to: segment_command_t.self).pointee

            if isEqualToLinkEdit(seg_cmd.segname) {
                linkEditBaseAddress = Int(seg_cmd.vmaddr - seg_cmd.fileoff) + slide
            }
        }

        cur = cur.advanced(by: loadCommand.cmdsize.intValue)
    }

    if let symtab_cmd = symtab_cmd, let dysymtab_cmd = dysymtab_cmd, let linkEditBaseAddress = linkEditBaseAddress {
        // 根据 LC_SYMTAB 中的 symbol table offset 获取 Symbol Table
        let symbolTable = UnsafeRawPointer(bitPattern: symtab_cmd.symoff.intValue + linkEditBaseAddress)?.assumingMemoryBound(to: nlist_t.self)
        // 根据 LC_SYMTAB 中的 string table offset 获取 String Table
        let stringTable = UnsafeRawPointer(bitPattern: symtab_cmd.stroff.intValue + linkEditBaseAddress)?.assumingMemoryBound(to: CChar.self)
        // 根据 LC_DYSYMTAB 中的 indirect symbol table offset 获取 Indirect Symbol Table
        let indirectSymbolTable = UnsafeRawPointer(bitPattern: dysymtab_cmd.indirectsymoff.intValue + linkEditBaseAddress)?.assumingMemoryBound(to: UInt32.self)

        return (symbolTable, stringTable, indirectSymbolTable)
    }

    return (nil, nil, nil)
}

private extension UInt32 {
    var intValue: Int { Int(self) }
}

private extension UInt64 {
    var intValue: Int { Int(self) }
}

private func isEqualToLinkEdit(_ v: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)) -> Bool {
    // 5F 5F 4C 49 4E 4B 45 44 49 54 000000000000 == __LINKEDIT
    return v.0 == 0x5F && v.1 == 0x5F && v.2 == 0x4C && v.3 == 0x49 && v.4 == 0x4E && v.5 == 0x4B && v.6 == 0x45 && v.7 == 0x44 && v.8 == 0x49 && v.9 == 0x54
}

// get seciton by name from header
private func _getsectbynamefromheader(_ mhp: UnsafePointer<mach_header_t>, _ segname: String, _ secname: String) -> UnsafePointer<section_t>? {
    #if arch(x86_64) || arch(arm64)
    return getsectbynamefromheader_64(mhp, segname, secname)
    #else
    return getsectbynamefromheader(mhp, segname, secname)
    #endif
}

