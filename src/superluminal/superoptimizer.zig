const std = @import("std");
const ir = @import("../ir/ir.zig");
const IRInstruction = ir.IRInstruction;
const IRValue = ir.IRValue;
const IROpcode = ir.IROpcode;
const cost_model = @import("cost_model.zig");
const Cost = cost_model.Cost;

const MAX_SUPEROPT_INSTR: usize = 20;

pub const Superoptimizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Superoptimizer {
        return .{ .allocator = allocator };
    }

    pub fn optimize(self: *Superoptimizer, instructions: []const IRInstruction) ![]const IRInstruction {
        if (instructions.len > MAX_SUPEROPT_INSTR or instructions.len < 2) {
            return instructions;
        }

        const baseline_cost = cost_model.evaluateSlice(instructions);

        var best_instrs = try self.allocator.dupe(IRInstruction, instructions);
        var best_cost = baseline_cost;

        const variants = [_]type{ ConstPropagate, StrengthReduce, DeadCodeElim };

        inline for (variants) |V| {
            const result = V.apply(self.allocator, instructions) catch null;
            if (result) |new_instrs| {
                defer self.allocator.free(new_instrs);
                const c = cost_model.evaluateSlice(new_instrs);
                if (c.total() < best_cost.total() * 0.95) {
                    self.allocator.free(best_instrs);
                    best_instrs = try self.allocator.dupe(IRInstruction, new_instrs);
                    best_cost = c;
                }
            }
        }

        return best_instrs;
    }
};

const ConstPropagate = struct {
    fn apply(allocator: std.mem.Allocator, instructions: []const IRInstruction) !?[]IRInstruction {
        const result = try allocator.dupe(IRInstruction, instructions);
        errdefer allocator.free(result);

        var const_regs = std.AutoHashMap(u32, IRValue).init(allocator);
        defer const_regs.deinit();

        for (result) |*instr| {
            if (instr.opcode == .load_const) {
                if (instr.dest) |d| {
                    try const_regs.put(d, instr.operand1);
                }
            }

            inline for (.{ &instr.operand1, &instr.operand2, &instr.operand3 }) |op| {
                if (op.* == .register) {
                    if (const_regs.get(op.register)) |const_val| {
                        op.* = const_val;
                    }
                }
            }
        }

        return result;
    }
};

const StrengthReduce = struct {
    fn apply(allocator: std.mem.Allocator, instructions: []const IRInstruction) !?[]IRInstruction {
        const result = try allocator.dupe(IRInstruction, instructions);
        errdefer allocator.free(result);

        for (result) |*instr| {
            if (instr.opcode == .mul) {
                if (instr.operand2 == .int) {
                    if (instr.operand2.int == 2) {
                        instr.opcode = .add;
                        instr.operand2 = instr.operand1;
                    }
                } else if (instr.operand1 == .int) {
                    if (instr.operand1.int == 2) {
                        instr.opcode = .add;
                        instr.operand1 = instr.operand2;
                        instr.operand2 = instr.operand1;
                    }
                }
            }
        }

        return result;
    }
};

const DeadCodeElim = struct {
    fn apply(allocator: std.mem.Allocator, instructions: []const IRInstruction) !?[]IRInstruction {
        var used_regs = std.AutoHashMap(u32, void).init(allocator);
        defer used_regs.deinit();

        for (instructions) |instr| {
            inline for (.{ instr.operand1, instr.operand2, instr.operand3 }) |op| {
                if (op == .register) {
                    try used_regs.put(op.register, {});
                }
            }
        }

        var result = std.ArrayList(IRInstruction).empty;
        errdefer result.deinit(allocator);

        for (instructions) |instr| {
            const has_side_effect = switch (instr.opcode) {
                .call, .ret, .store_var, .store_field, .jump, .jump_if_false, .label, .begin_block, .end_block, .arg, .list_push, .list_create, .map_set, .map_create, .union_create, .result_ok, .result_err, .db_get, .db_set, .db_all, .db_where, .http_response, .alloc, .free => true,
                else => false,
            };

            if (has_side_effect) {
                try result.append(allocator, instr);
            } else if (instr.dest) |d| {
                if (used_regs.contains(d)) {
                    try result.append(allocator, instr);
                }
            } else {
                try result.append(allocator, instr);
            }
        }

        return try result.toOwnedSlice(allocator);
    }
};
