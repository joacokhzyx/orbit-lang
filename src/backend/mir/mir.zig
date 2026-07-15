//! orbit/src/backend/mir/mir.zig
//!
//! Target-independent Mid-level Intermediate Representation (MIR).
//! Defines the MIR structure, basic blocks, instructions, and values.
//! MIR has explicit basic blocks, CFG structure, and SSA-like or flat register value IDs.
//!
//! Specifications: SSA-based Compiler Design principles.

const std = @import("std");

/// Target-independent MIR Opcodes.
pub const MirOpcode = enum {
    nop,
    arg,

    // Constants & Memory
    const_int,
    const_float,
    const_bool,
    const_str,
    copy,

    // Memory Reference
    alloc_stack,
    load_stack,
    store_stack,

    // Arithmetic & Bitwise
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    and_op,
    or_op,
    not_op,
    xor_op,
    shl,
    shr,

    // Comparisons
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    // Control Flow
    jmp,
    jmp_if,
    ret,
    call,

    // Orbit Specific Runtime Ops
    arena_alloc, // Call runtime arena allocation
    kynx_lease_check, // Verify lease limits
    kynx_lease_end, // End lease execution
    db_query, // Execute DB statement
    http_write, // Send response via http
};

/// Represents an identifier for a MIR virtual register or value.
pub const ValueId = u32;

/// A typed value in MIR.
pub const MirType = enum {
    int,
    float,
    string,
    bool,
    void,
    ptr, // Generic pointer (for runtime structs, arenas)
};

/// A MIR operand.
pub const MirOperand = union(enum) {
    none,
    reg: ValueId,
    imm_int: i64,
    imm_float: f64,
    imm_bool: bool,
    imm_str: []const u8,
    block: u32, // Target basic block index
};

/// A target-independent MIR instruction.
pub const MirInstruction = struct {
    opcode: MirOpcode,
    dest: ?ValueId,
    op1: MirOperand = .none,
    op2: MirOperand = .none,
    op3: MirOperand = .none,
    src_line: u32 = 0,
};

/// A basic block containing a linear sequence of instructions and ending with a terminator.
pub const MirBasicBlock = struct {
    id: u32,
    name: []const u8,
    instructions: std.ArrayListUnmanaged(MirInstruction) = .empty,
    predecessors: std.ArrayListUnmanaged(u32) = .empty,
    successors: std.ArrayListUnmanaged(u32) = .empty,

    pub fn deinit(self: *MirBasicBlock, allocator: std.mem.Allocator) void {
        self.instructions.deinit(allocator);
        self.predecessors.deinit(allocator);
        self.successors.deinit(allocator);
    }
};

/// A target-independent MIR function.
pub const MirFunction = struct {
    name: []const u8,
    blocks: std.ArrayListUnmanaged(MirBasicBlock) = .empty,
    param_types: []const MirType,
    return_type: MirType,
    val_types: std.ArrayListUnmanaged(MirType) = .empty, // Types of virtual registers
    is_route: bool = false,
    route_method: []const u8 = "",
    route_path: []const u8 = "",

    pub fn deinit(self: *MirFunction, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*block| {
            block.deinit(allocator);
        }
        self.blocks.deinit(allocator);
        self.val_types.deinit(allocator);
        allocator.free(self.param_types);
    }

    pub fn addRegister(self: *MirFunction, allocator: std.mem.Allocator, t: MirType) !ValueId {
        try self.val_types.append(allocator, t);
        return @intCast(self.val_types.items.len - 1);
    }
};

/// A complete target-independent MIR module.
pub const MirModule = struct {
    functions: std.ArrayListUnmanaged(MirFunction) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MirModule {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MirModule) void {
        for (self.functions.items) |*func| {
            func.deinit(self.allocator);
        }
        self.functions.deinit(self.allocator);
    }
};
