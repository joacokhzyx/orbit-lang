//! orbit/src/backend/lir/lir.zig
//!
//! Low-level Intermediate Representation (LIR).
//! Represents virtual/physical registers, stack slots, calling convention parameters,
//! instruction encoding details, and memory operands.
//!
//! Specifications: Modern Compiler Implementation in C (Appel), Chapter 9 on Instruction Selection.

const std = @import("std");

/// Target-independent representation of physical and virtual registers.
pub const LirRegister = struct {
    id: u32,
    is_physical: bool = false,
    class: RegisterClass = .gp,

    pub const RegisterClass = enum {
        gp, // General Purpose
        xmm, // Float/vector
    };
};

/// A memory address operand: [base_reg + index_reg * scale + disp]
pub const LirMemoryRef = struct {
    base: ?LirRegister = null,
    index: ?LirRegister = null,
    scale: u3 = 1,
    disp: i32 = 0,
};

/// An operand in LIR.
pub const LirOperand = union(enum) {
    none,
    reg: LirRegister,
    imm_int: i64,
    imm_float: f64,
    stack_slot: u32, // Stack offset index
    mem: LirMemoryRef,
    label: u32, // Target block index
    symbol: []const u8, // External reference symbol
};

/// A target-specific instruction in LIR.
pub const LirInstruction = struct {
    opcode: u32, // Target opcode (cast to x86_64 opcode)
    dest: ?LirRegister = null,
    op1: LirOperand = .none,
    op2: LirOperand = .none,
    op3: LirOperand = .none,
    src_line: u32 = 0,
};

/// A LIR basic block.
pub const LirBasicBlock = struct {
    id: u32,
    instructions: std.ArrayListUnmanaged(LirInstruction) = .empty,

    pub fn deinit(self: *LirBasicBlock, allocator: std.mem.Allocator) void {
        self.instructions.deinit(allocator);
    }
};

/// A LIR function.
pub const LirFunction = struct {
    name: []const u8,
    blocks: std.ArrayListUnmanaged(LirBasicBlock) = .empty,
    stack_size: u32 = 0,
    spill_slots: u32 = 0,
    is_route: bool = false,
    route_method: []const u8 = "",
    route_path: []const u8 = "",

    pub fn deinit(self: *LirFunction, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*block| {
            block.deinit(allocator);
        }
        self.blocks.deinit(allocator);
        if (self.is_route) {
            allocator.free(self.route_method);
            allocator.free(self.route_path);
        }
    }
};

/// A LIR module.
pub const LirModule = struct {
    functions: std.ArrayListUnmanaged(LirFunction) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LirModule {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LirModule) void {
        for (self.functions.items) |*func| {
            func.deinit(self.allocator);
        }
        self.functions.deinit(self.allocator);
    }
};
