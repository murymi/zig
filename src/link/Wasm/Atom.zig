const Atom = @This();

const std = @import("std");
const types = @import("types.zig");
const Wasm = @import("../Wasm.zig");
const Symbol = @import("Symbol.zig");

const leb = std.leb;
const log = std.log.scoped(.link);
const mem = std.mem;
const Allocator = mem.Allocator;

/// symbol index of the symbol representing this atom
sym_index: u32,
/// Size of the atom, used to calculate section sizes in the final binary
size: u32,
/// List of relocations belonging to this atom
relocs: std.ArrayListUnmanaged(types.Relocation) = .{},
/// Contains the binary data of an atom, which can be non-relocated
code: std.ArrayListUnmanaged(u8) = .{},
/// For code this is 1, for data this is set to the highest value of all segments
alignment: Wasm.Alignment,
/// Offset into the section where the atom lives, this already accounts
/// for alignment.
offset: u32,
/// Represents the index of the file this atom was generated from.
/// This is 'null' when the atom was generated by a Decl from Zig code.
file: ?u16,

/// Next atom in relation to this atom.
/// When null, this atom is the last atom
next: ?Atom.Index,
/// Previous atom in relation to this atom.
/// is null when this atom is the first in its order
prev: ?Atom.Index,

/// Contains atoms local to a decl, all managed by this `Atom`.
/// When the parent atom is being freed, it will also do so for all local atoms.
locals: std.ArrayListUnmanaged(Atom.Index) = .{},

/// Alias to an unsigned 32-bit integer
pub const Index = u32;

/// Represents a default empty wasm `Atom`
pub const empty: Atom = .{
    .alignment = .@"1",
    .file = null,
    .next = null,
    .offset = 0,
    .prev = null,
    .size = 0,
    .sym_index = 0,
};

/// Frees all resources owned by this `Atom`.
pub fn deinit(atom: *Atom, wasm: *Wasm) void {
    const gpa = wasm.base.allocator;
    atom.relocs.deinit(gpa);
    atom.code.deinit(gpa);
    atom.locals.deinit(gpa);
    atom.* = undefined;
}

/// Sets the length of relocations and code to '0',
/// effectively resetting them and allowing them to be re-populated.
pub fn clear(atom: *Atom) void {
    atom.relocs.clearRetainingCapacity();
    atom.code.clearRetainingCapacity();
}

pub fn format(atom: Atom, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;
    try writer.print("Atom{{ .sym_index = {d}, .alignment = {d}, .size = {d}, .offset = 0x{x:0>8} }}", .{
        atom.sym_index,
        atom.alignment,
        atom.size,
        atom.offset,
    });
}

/// Returns the location of the symbol that represents this `Atom`
pub fn symbolLoc(atom: Atom) Wasm.SymbolLoc {
    return .{ .file = atom.file, .index = atom.sym_index };
}

pub fn getSymbolIndex(atom: Atom) ?u32 {
    if (atom.sym_index == 0) return null;
    return atom.sym_index;
}

/// Resolves the relocations within the atom, writing the new value
/// at the calculated offset.
pub fn resolveRelocs(atom: *Atom, wasm_bin: *const Wasm) void {
    if (atom.relocs.items.len == 0) return;
    const symbol_name = atom.symbolLoc().getName(wasm_bin);
    log.debug("Resolving relocs in atom '{s}' count({d})", .{
        symbol_name,
        atom.relocs.items.len,
    });

    for (atom.relocs.items) |reloc| {
        const value = atom.relocationValue(reloc, wasm_bin);
        log.debug("Relocating '{s}' referenced in '{s}' offset=0x{x:0>8} value={d}", .{
            (Wasm.SymbolLoc{ .file = atom.file, .index = reloc.index }).getName(wasm_bin),
            symbol_name,
            reloc.offset,
            value,
        });

        switch (reloc.relocation_type) {
            .R_WASM_TABLE_INDEX_I32,
            .R_WASM_FUNCTION_OFFSET_I32,
            .R_WASM_GLOBAL_INDEX_I32,
            .R_WASM_MEMORY_ADDR_I32,
            .R_WASM_SECTION_OFFSET_I32,
            => std.mem.writeIntLittle(u32, atom.code.items[reloc.offset..][0..4], @as(u32, @intCast(value))),
            .R_WASM_TABLE_INDEX_I64,
            .R_WASM_MEMORY_ADDR_I64,
            => std.mem.writeIntLittle(u64, atom.code.items[reloc.offset..][0..8], value),
            .R_WASM_GLOBAL_INDEX_LEB,
            .R_WASM_EVENT_INDEX_LEB,
            .R_WASM_FUNCTION_INDEX_LEB,
            .R_WASM_MEMORY_ADDR_LEB,
            .R_WASM_MEMORY_ADDR_SLEB,
            .R_WASM_TABLE_INDEX_SLEB,
            .R_WASM_TABLE_NUMBER_LEB,
            .R_WASM_TYPE_INDEX_LEB,
            .R_WASM_MEMORY_ADDR_TLS_SLEB,
            => leb.writeUnsignedFixed(5, atom.code.items[reloc.offset..][0..5], @as(u32, @intCast(value))),
            .R_WASM_MEMORY_ADDR_LEB64,
            .R_WASM_MEMORY_ADDR_SLEB64,
            .R_WASM_TABLE_INDEX_SLEB64,
            .R_WASM_MEMORY_ADDR_TLS_SLEB64,
            => leb.writeUnsignedFixed(10, atom.code.items[reloc.offset..][0..10], value),
        }
    }
}

/// From a given `relocation` will return the new value to be written.
/// All values will be represented as a `u64` as all values can fit within it.
/// The final value must be casted to the correct size.
fn relocationValue(atom: Atom, relocation: types.Relocation, wasm_bin: *const Wasm) u64 {
    const target_loc = (Wasm.SymbolLoc{ .file = atom.file, .index = relocation.index }).finalLoc(wasm_bin);
    const symbol = target_loc.getSymbol(wasm_bin);
    switch (relocation.relocation_type) {
        .R_WASM_FUNCTION_INDEX_LEB => return symbol.index,
        .R_WASM_TABLE_NUMBER_LEB => return symbol.index,
        .R_WASM_TABLE_INDEX_I32,
        .R_WASM_TABLE_INDEX_I64,
        .R_WASM_TABLE_INDEX_SLEB,
        .R_WASM_TABLE_INDEX_SLEB64,
        => return wasm_bin.function_table.get(target_loc) orelse 0,
        .R_WASM_TYPE_INDEX_LEB => {
            const file_index = atom.file orelse {
                return relocation.index;
            };

            const original_type = wasm_bin.objects.items[file_index].func_types[relocation.index];
            return wasm_bin.getTypeIndex(original_type).?;
        },
        .R_WASM_GLOBAL_INDEX_I32,
        .R_WASM_GLOBAL_INDEX_LEB,
        => return symbol.index,
        .R_WASM_MEMORY_ADDR_I32,
        .R_WASM_MEMORY_ADDR_I64,
        .R_WASM_MEMORY_ADDR_LEB,
        .R_WASM_MEMORY_ADDR_LEB64,
        .R_WASM_MEMORY_ADDR_SLEB,
        .R_WASM_MEMORY_ADDR_SLEB64,
        => {
            std.debug.assert(symbol.tag == .data);
            if (symbol.isUndefined()) {
                return 0;
            }
            const va = @as(i64, @intCast(symbol.virtual_address));
            return @intCast(va + relocation.addend);
        },
        .R_WASM_EVENT_INDEX_LEB => return symbol.index,
        .R_WASM_SECTION_OFFSET_I32 => {
            const target_atom_index = wasm_bin.symbol_atom.get(target_loc).?;
            const target_atom = wasm_bin.getAtom(target_atom_index);
            const rel_value: i32 = @intCast(target_atom.offset);
            return @intCast(rel_value + relocation.addend);
        },
        .R_WASM_FUNCTION_OFFSET_I32 => {
            const target_atom_index = wasm_bin.symbol_atom.get(target_loc) orelse {
                return @as(u32, @bitCast(@as(i32, -1)));
            };
            const target_atom = wasm_bin.getAtom(target_atom_index);
            const offset: u32 = 11 + Wasm.getULEB128Size(target_atom.size); // Header (11 bytes fixed-size) + body size (leb-encoded)
            const rel_value: i32 = @intCast(target_atom.offset + offset);
            return @intCast(rel_value + relocation.addend);
        },
        .R_WASM_MEMORY_ADDR_TLS_SLEB,
        .R_WASM_MEMORY_ADDR_TLS_SLEB64,
        => {
            const va: i32 = @intCast(symbol.virtual_address);
            return @intCast(va + relocation.addend);
        },
    }
}
