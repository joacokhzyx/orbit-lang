//! orbit/src/ir/optimizer.zig
//!
//! Applies optimisation passes over an `IRModule` before C code generation.
//! Current passes: constant folding, dead-code elimination, and basic
//! strength-reduction for arithmetic expressions.

const std = @import("std");
const ir_mod = @import("ir.zig");
const IRModule = ir_mod.IRModule;
const IRFunction = ir_mod.IRFunction;
const IRInstruction = ir_mod.IRInstruction;
const IROpcode = ir_mod.IROpcode;
const IRValue = ir_mod.IRValue;

pub const ConstantFolder = struct {
    allocator: std.mem.Allocator,
    folded_count: usize,

    pub fn init(allocator: std.mem.Allocator) ConstantFolder {
        return .{
            .allocator = allocator,
            .folded_count = 0,
        };
    }

    pub fn optimize(self: *ConstantFolder, module: *IRModule) !void {
        for (module.functions.items) |*func| {
            try self.optimizeFunction(func);
        }
    }

    fn optimizeFunction(self: *ConstantFolder, func: *IRFunction) !void {
        var i: usize = 0;
        while (i < func.instructions.items.len) {
            const instr = &func.instructions.items[i];

            if (try self.foldInstruction(instr)) {
                self.folded_count += 1;
            }

            i += 1;
        }
    }

    fn foldInstruction(self: *ConstantFolder, instr: *IRInstruction) !bool {
        _ = self;

        switch (instr.opcode) {
            .add => {
                if (instr.operand1 == .int and instr.operand2 == .int) {
                    const result = instr.operand1.int + instr.operand2.int;
                    instr.opcode = .load_const;
                    instr.operand1 = IRValue{ .int = result };
                    instr.operand2 = .none;
                    return true;
                }
                if (instr.operand1 == .int and instr.operand1.int == 0) {
                    instr.opcode = .copy; // x + 0 = x
                    instr.operand1 = instr.operand2;
                    instr.operand2 = .none;
                    return true;
                }
                if (instr.operand2 == .int and instr.operand2.int == 0) {
                    instr.opcode = .copy; // x + 0 = x
                    instr.operand2 = .none;
                    return true;
                }
            },
            .mul => {
                if (instr.operand1 == .int and instr.operand2 == .int) {
                    const result = instr.operand1.int * instr.operand2.int;
                    instr.opcode = .load_const;
                    instr.operand1 = IRValue{ .int = result };
                    instr.operand2 = .none;
                    return true;
                }
                if (instr.operand1 == .int and instr.operand1.int == 1) {
                    instr.opcode = .copy; // 1 * x = x
                    instr.operand1 = instr.operand2;
                    instr.operand2 = .none;
                    return true;
                }
                if (instr.operand2 == .int and instr.operand2.int == 1) {
                    instr.opcode = .copy; // x * 1 = x
                    instr.operand2 = .none;
                    return true;
                }
                if (instr.operand2 == .int and instr.operand2.int == 2) {
                    instr.opcode = .add; // x * 2 = x + x
                    instr.operand2 = instr.operand1;
                    return true;
                }
                if ((instr.operand1 == .int and instr.operand1.int == 0) or
                    (instr.operand2 == .int and instr.operand2.int == 0))
                {
                    instr.opcode = .load_const; // x * 0 = 0
                    instr.operand1 = IRValue{ .int = 0 };
                    instr.operand2 = .none;
                    return true;
                }
            },
            .sub => {
                if (instr.operand1 == .int and instr.operand2 == .int) {
                    const result = instr.operand1.int - instr.operand2.int;
                    instr.opcode = .load_const;
                    instr.operand1 = IRValue{ .int = result };
                    instr.operand2 = .none;
                    return true;
                }
                if (instr.operand2 == .int and instr.operand2.int == 0) {
                    instr.opcode = .copy; // x - 0 = x
                    instr.operand2 = .none;
                    return true;
                }
            },
            .div => {
                if (instr.operand1 == .int and instr.operand2 == .int and instr.operand2.int != 0) {
                    const result = @divTrunc(instr.operand1.int, instr.operand2.int);
                    instr.opcode = .load_const;
                    instr.operand1 = IRValue{ .int = result };
                    instr.operand2 = .none;
                    return true;
                }
            },
            else => {},
        }

        return false;
    }
};

pub const LoopUnroller = struct {
    allocator: std.mem.Allocator,
    unroll_count: usize,
    max_unroll_factor: usize,

    pub fn init(allocator: std.mem.Allocator) LoopUnroller {
        return .{
            .allocator = allocator,
            .unroll_count = 0,
            .max_unroll_factor = 4,
        };
    }

    pub fn optimize(self: *LoopUnroller, module: *IRModule) !void {
        for (module.functions.items) |*func| {
            try self.optimizeFunction(func);
        }
    }

    fn optimizeFunction(self: *LoopUnroller, func: *IRFunction) !void {
        _ = self;
        var i: usize = 0;
        while (i < func.instructions.items.len) {
            const instr = func.instructions.items[i];

            // Very basic loop unrolling: detect label + jump_if_false pattern
            if (instr.opcode == .label) {
                // ... logic to unroll small loops ...
            }

            i += 1;
        }
    }
};

pub const EscapeAnalyzer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EscapeAnalyzer {
        return .{ .allocator = allocator };
    }

    pub fn analyze(self: *EscapeAnalyzer, func: *IRFunction) !void {
        var escapes = std.AutoHashMapUnmanaged(u32, bool){};
        defer escapes.deinit(self.allocator);

        for (func.instructions.items) |instr| {
            switch (instr.opcode) {
                .ret => {
                    if (instr.operand1 == .register) {
                        try escapes.put(self.allocator, instr.operand1.register, true);
                    }
                },
                else => {},
            }
        }
    }
};

pub const DeadCodeEliminator = struct {
    allocator: std.mem.Allocator,
    eliminated_count: usize,

    pub fn init(allocator: std.mem.Allocator) DeadCodeEliminator {
        return .{
            .allocator = allocator,
            .eliminated_count = 0,
        };
    }

    pub fn optimize(self: *DeadCodeEliminator, module: *IRModule) !void {
        for (module.functions.items) |*func| {
            try self.optimizeFunction(func);
        }
    }

    fn optimizeFunction(self: *DeadCodeEliminator, func: *IRFunction) !void {
        var used_registers = std.AutoHashMapUnmanaged(u32, bool){};
        defer used_registers.deinit(self.allocator);

        for (func.instructions.items) |instr| {
            switch (instr.operand1) {
                .register => |reg| try used_registers.put(self.allocator, reg, true),
                else => {},
            }
            switch (instr.operand2) {
                .register => |reg| try used_registers.put(self.allocator, reg, true),
                else => {},
            }
            switch (instr.operand3) {
                .register => |reg| try used_registers.put(self.allocator, reg, true),
                else => {},
            }
        }

        var i: usize = 0;
        while (i < func.instructions.items.len) {
            const instr = func.instructions.items[i];

            if (instr.dest) |dest| {
                if (!used_registers.contains(dest) and instr.opcode != .ret and instr.opcode != .call) {
                    _ = func.instructions.orderedRemove(i);
                    self.eliminated_count += 1;
                    continue;
                }
            }

            i += 1;
        }
    }
};

pub const InlineOptimizer = struct {
    allocator: std.mem.Allocator,
    inlined_count: usize,
    max_inline_size: usize,

    pub fn init(allocator: std.mem.Allocator) InlineOptimizer {
        return .{
            .allocator = allocator,
            .inlined_count = 0,
            .max_inline_size = 10,
        };
    }

    pub fn optimize(self: *InlineOptimizer, module: *IRModule) !void {
        var inline_candidates = std.StringHashMapUnmanaged(*IRFunction){};
        defer inline_candidates.deinit(self.allocator);

        for (module.functions.items) |*func| {
            if (func.instructions.items.len <= self.max_inline_size) {
                try inline_candidates.put(self.allocator, func.name, func);
            }
        }

        for (module.functions.items) |*func| {
            try self.inlineInFunction(func, &inline_candidates);
        }
    }

    fn inlineInFunction(self: *InlineOptimizer, func: *IRFunction, candidates: *std.StringHashMapUnmanaged(*IRFunction)) !void {
        var i: usize = 0;
        while (i < func.instructions.items.len) {
            const instr = &func.instructions.items[i];
            if (instr.opcode == .call and instr.operand1 == .symbol) {
                const callee_name = instr.operand1.symbol;
                if (candidates.get(callee_name)) |callee| {
                    const call_dest = instr.dest;

                    var arg_start = i;
                    while (arg_start > 0) {
                        arg_start -= 1;
                        if (func.instructions.items[arg_start].opcode != .arg) {
                            arg_start += 1;
                            break;
                        }
                    }

                    var arg_regs = std.ArrayListUnmanaged(u32){};
                    defer arg_regs.deinit(self.allocator);

                    var k = arg_start;
                    while (k < i) : (k += 1) {
                        const arg_instr = func.instructions.items[k];
                        if (arg_instr.operand1 == .register) {
                            try arg_regs.append(self.allocator, arg_instr.operand1.register);
                        }
                    }

                    const base_reg = func.register_count;
                    const callee_reg_count = callee.register_count;
                    func.register_count += callee_reg_count;
                    try func.register_types.appendNTimes(self.allocator, .unknown, callee_reg_count);

                    var callee_instrs = std.ArrayListUnmanaged(IRInstruction){};
                    defer callee_instrs.deinit(self.allocator);
                    try callee_instrs.ensureTotalCapacity(self.allocator, callee.instructions.items.len);

                    for (callee.instructions.items) |ci| {
                        var new_instr = ci;
                        if (new_instr.dest) |d| {
                            new_instr.dest = base_reg + d;
                        }
                        if (new_instr.operand1 == .register) {
                            new_instr.operand1 = IRValue{ .register = new_instr.operand1.register + base_reg };
                        }
                        if (new_instr.operand2 == .register) {
                            new_instr.operand2 = IRValue{ .register = new_instr.operand2.register + base_reg };
                        }
                        if (new_instr.operand3 == .register) {
                            new_instr.operand3 = IRValue{ .register = new_instr.operand3.register + base_reg };
                        }

                        if (new_instr.opcode == .ret and call_dest) |dest| {
                            const copy_instr = IRInstruction{
                                .opcode = .copy,
                                .dest = dest,
                                .operand1 = new_instr.operand1,
                                .operand2 = .none,
                                .operand3 = .none,
                            };
                            callee_instrs.appendAssumeCapacity(copy_instr);
                        } else {
                            callee_instrs.appendAssumeCapacity(new_instr);
                        }
                    }

                    var param_copies = std.ArrayListUnmanaged(IRInstruction){};
                    defer param_copies.deinit(self.allocator);
                    try param_copies.ensureTotalCapacity(self.allocator, callee.params.len);

                    for (callee.params, 0..) |_, param_idx| {
                        if (param_idx < arg_regs.items.len) {
                            const param_reg = base_reg + param_idx;
                            const copy_instr = IRInstruction{
                                .opcode = .copy,
                                .dest = param_reg,
                                .operand1 = IRValue{ .register = arg_regs.items[param_idx] },
                                .operand2 = .none,
                                .operand3 = .none,
                            };
                            param_copies.appendAssumeCapacity(copy_instr);
                        }
                    }

                    const removal_count = i - arg_start + 1;
                    var ri: usize = 0;
                    while (ri < removal_count) : (ri += 1) {
                        _ = func.instructions.orderedRemove(arg_start);
                        i -= 1;
                    }

                    var insert_pos = arg_start;
                    for (param_copies.items) |pc| {
                        try func.instructions.insert(self.allocator, insert_pos, pc);
                        insert_pos += 1;
                        i += 1;
                    }
                    for (callee_instrs.items) |ci| {
                        try func.instructions.insert(self.allocator, insert_pos, ci);
                        insert_pos += 1;
                        i += 1;
                    }

                    self.inlined_count += 1;
                    continue;
                }
            }
            i += 1;
        }
    }
};

pub const CommonSubexpressionEliminator = struct {
    allocator: std.mem.Allocator,
    eliminated_count: usize,

    pub fn init(allocator: std.mem.Allocator) CommonSubexpressionEliminator {
        return .{
            .allocator = allocator,
            .eliminated_count = 0,
        };
    }

    pub fn optimize(self: *CommonSubexpressionEliminator, module: *IRModule) !void {
        for (module.functions.items) |*func| {
            try self.optimizeFunction(func);
        }
    }

    const ExprKey = struct {
        opcode: IROpcode,
        op1: IRValue,
        op2: IRValue,

        pub fn hash(self: ExprKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&self.opcode));
            h.update(std.mem.asBytes(&self.op1));
            h.update(std.mem.asBytes(&self.op2));
            return h.final();
        }

        pub fn eql(self: ExprKey, other: ExprKey) bool {
            return self.opcode == other.opcode and
                std.meta.eql(self.op1, other.op1) and
                std.meta.eql(self.op2, other.op2);
        }
    };

    fn optimizeFunction(self: *CommonSubexpressionEliminator, func: *IRFunction) !void {
        const Context = struct {
            pub fn hash(ctx_self: @This(), key: ExprKey) u64 {
                _ = ctx_self;
                return key.hash();
            }
            pub fn eql(ctx_self: @This(), a: ExprKey, b: ExprKey) bool {
                _ = ctx_self;
                return a.eql(b);
            }
        };
        var available_exprs = std.HashMapUnmanaged(ExprKey, u32, Context, std.hash_map.default_max_load_percentage){};
        defer available_exprs.deinit(self.allocator);

        var i: usize = 0;
        while (i < func.instructions.items.len) {
            const instr = &func.instructions.items[i];

            if (instr.opcode == .add or instr.opcode == .sub or instr.opcode == .mul or instr.opcode == .div) {
                const key = ExprKey{
                    .opcode = instr.opcode,
                    .op1 = instr.operand1,
                    .op2 = instr.operand2,
                };

                if (available_exprs.get(key)) |reg| {
                    instr.opcode = .copy;
                    instr.operand1 = IRValue{ .register = reg };
                    instr.operand2 = .none;
                    self.eliminated_count += 1;
                } else {
                    if (instr.dest) |dest| {
                        try available_exprs.put(self.allocator, key, dest);
                    }
                }
            }

            i += 1;
        }
    }
};

pub const CopyPropagator = struct {
    allocator: std.mem.Allocator,
    propagated_count: usize,

    pub fn init(allocator: std.mem.Allocator) CopyPropagator {
        return .{
            .allocator = allocator,
            .propagated_count = 0,
        };
    }

    pub fn optimize(self: *CopyPropagator, module: *IRModule) !void {
        for (module.functions.items) |*func| {
            try self.optimizeFunction(func);
        }
    }

    fn optimizeFunction(self: *CopyPropagator, func: *IRFunction) !void {
        var replacements = std.AutoHashMapUnmanaged(u32, IRValue){};
        defer replacements.deinit(self.allocator);

        var i: usize = 0;
        while (i < func.instructions.items.len) {
            const instr = &func.instructions.items[i];

            if (instr.operand1 == .register) {
                if (replacements.get(instr.operand1.register)) |rep| {
                    instr.operand1 = rep;
                    self.propagated_count += 1;
                }
            }
            if (instr.operand2 == .register) {
                if (replacements.get(instr.operand2.register)) |rep| {
                    instr.operand2 = rep;
                    self.propagated_count += 1;
                }
            }
            if (instr.operand3 == .register) {
                if (replacements.get(instr.operand3.register)) |rep| {
                    instr.operand3 = rep;
                    self.propagated_count += 1;
                }
            }

            if (instr.opcode == .copy) {
                if (instr.dest) |dest| {
                    try replacements.put(self.allocator, dest, instr.operand1);
                }
            } else if (instr.opcode == .load_var) {
                if (instr.dest) |dest| {
                    try replacements.put(self.allocator, dest, IRValue{ .symbol = instr.operand1.string });
                }
            } else if (instr.opcode == .store_var) {
                replacements.clearRetainingCapacity();
            } else if (instr.opcode == .label) {
                replacements.clearRetainingCapacity();
            }

            i += 1;
        }
    }
};
