//! orbit/src/backend/mir/builder.zig
//!
//! Lowers Orbit IR (HIR) into structured MIR functions with explicit basic blocks
//! and Control Flow Graphs (CFG).
//!
//! References: Modern Compiler Implementation in ML/C (Appel), Chapter 8 on Basic Blocks.

const std = @import("std");
const ir_mod = @import("../../ir/ir.zig");
const IRModule = ir_mod.IRModule;
const IRFunction = ir_mod.IRFunction;
const IROpcode = ir_mod.IROpcode;
const IRValue = ir_mod.IRValue;
const IRType = ir_mod.IRType;

const mir_mod = @import("mir.zig");
const MirModule = mir_mod.MirModule;
const MirFunction = mir_mod.MirFunction;
const MirBasicBlock = mir_mod.MirBasicBlock;
const MirInstruction = mir_mod.MirInstruction;
const MirOpcode = mir_mod.MirOpcode;
const MirOperand = mir_mod.MirOperand;
const MirType = mir_mod.MirType;
const ValueId = mir_mod.ValueId;

const layout_mod = @import("model_layout.zig");
const ModelLayout = layout_mod.ModelLayout;

pub const MirBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MirBuilder {
        return .{ .allocator = allocator };
    }

    /// Converts an `IRModule` into a structured `MirModule`.
    pub fn build(self: *MirBuilder, ir_module: *const IRModule) !MirModule {
        var mir_module = MirModule.init(self.allocator);
        errdefer mir_module.deinit();

        var layout = try ModelLayout.compute(self.allocator, ir_module);
        defer layout.deinit(self.allocator);

        for (ir_module.functions.items) |*ir_func| {
            const mir_func = try self.buildFunction(ir_func, &layout);
            try mir_module.functions.append(self.allocator, mir_func);
        }

        return mir_module;
    }

    fn mapType(t: IRType) MirType {
        return switch (t) {
            .int => .int,
            .float => .float,
            .string => .string,
            .bool => .bool,
            .void => .void,
            else => .ptr,
        };
    }

    fn buildFunction(self: *MirBuilder, ir_func: *const IRFunction, layout: *const ModelLayout) !MirFunction {

        // Map parameter types
        var param_types = try self.allocator.alloc(MirType, ir_func.params.len);
        for (ir_func.param_types, 0..) |pt, i| {
            param_types[i] = mapType(pt);
        }

        var mir_func = MirFunction{
            .name = try self.allocator.dupe(u8, ir_func.name),
            .param_types = param_types,
            .return_type = mapType(ir_func.return_type),
        };
        errdefer mir_func.deinit(self.allocator);

        // Pre-allocate register types mapping
        for (ir_func.register_types.items) |rt| {
            _ = try mir_func.addRegister(self.allocator, mapType(rt));
        }

        var variable_map = std.StringHashMap(ValueId).init(self.allocator);
        defer variable_map.deinit();

        // Allocate registers for parameters
        for (ir_func.params, ir_func.param_types) |p_name, p_type| {
            const reg_id = try mir_func.addRegister(self.allocator, mapType(p_type));
            try variable_map.put(p_name, reg_id);
        }

        // First pass: scan for labels to identify basic block boundaries.
        // We split blocks at:
        // 1. Any instruction preceded by a label.
        // 2. The start of the function.
        // 3. Immediately after a jump or branch (to start a new block).
        var block_starts = std.AutoHashMap(usize, []const u8).init(self.allocator);
        defer block_starts.deinit();

        // Always start block at index 0
        try block_starts.put(0, "entry");

        for (ir_func.instructions.items, 0..) |instr, i| {
            if (instr.opcode == .label) {
                const label_name = if (instr.operand1 == .string) instr.operand1.string else "bb";
                try block_starts.put(i, label_name);
            }
            if (instr.opcode == .jump or instr.opcode == .jump_if_false or instr.opcode == .ret) {
                if (i + 1 < ir_func.instructions.items.len) {
                    try block_starts.put(i + 1, "split");
                }
            }
        }

        // Map instruction index to block ID.
        var idx_to_block = std.AutoHashMap(usize, u32).init(self.allocator);
        defer idx_to_block.deinit();

        var sorted_starts = std.ArrayListUnmanaged(usize).empty;
        defer sorted_starts.deinit(self.allocator);

        var it = block_starts.keyIterator();
        while (it.next()) |key| {
            try sorted_starts.append(self.allocator, key.*);
        }
        std.mem.sort(usize, sorted_starts.items, {}, std.sort.asc(usize));

        // Create basic blocks
        for (sorted_starts.items, 0..) |start_idx, block_id| {
            const name = block_starts.get(start_idx).?;
            const name_owned = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ name, block_id });
            try mir_func.blocks.append(self.allocator, MirBasicBlock{
                .id = @intCast(block_id),
                .name = name_owned,
            });
            try idx_to_block.put(start_idx, @intCast(block_id));
        }

        // Populate basic blocks with instructions
        var current_block_id: u32 = 0;
        for (ir_func.instructions.items, 0..) |ir_instr, i| {
            if (block_starts.get(i)) |_| {
                if (idx_to_block.get(i)) |bid| {
                    current_block_id = bid;
                }
            }

            // Lower instruction to MIR
            const mir_instr = try self.lowerInstruction(ir_instr, &idx_to_block, ir_func.instructions.items, &variable_map, &mir_func, ir_func, layout);
            if (mir_instr.opcode != .nop) {
                try mir_func.blocks.items[current_block_id].instructions.append(self.allocator, mir_instr);
            }
        }

        // Second pass: resolve jumps to exact basic block IDs and construct CFG.
        for (mir_func.blocks.items) |*block| {
            if (block.instructions.items.len == 0) continue;
            const last_idx = block.instructions.items.len - 1;
            var last = &block.instructions.items[last_idx];

            if (last.opcode == .jmp) {
                const target_ir_idx = last.op1.imm_int;
                const target_bid = idx_to_block.get(@intCast(target_ir_idx)) orelse return error.UnresolvedBlock;
                last.op1 = .{ .block = target_bid };
                try addCfgEdge(block, &mir_func.blocks.items[target_bid], self.allocator);
            } else if (last.opcode == .jmp_if) {
                const target_ir_idx = last.op2.imm_int;
                const target_bid = idx_to_block.get(@intCast(target_ir_idx)) orelse return error.UnresolvedBlock;
                last.op2 = .{ .block = target_bid };
                try addCfgEdge(block, &mir_func.blocks.items[target_bid], self.allocator);

                // Fallthrough edge
                const next_bid = block.id + 1;
                if (next_bid < mir_func.blocks.items.len) {
                    try addCfgEdge(block, &mir_func.blocks.items[next_bid], self.allocator);
                }
            } else if (last.opcode == .ret) {
                // No successors
            } else {
                // Implicit fallthrough to next block
                const next_bid = block.id + 1;
                if (next_bid < mir_func.blocks.items.len) {
                    try addCfgEdge(block, &mir_func.blocks.items[next_bid], self.allocator);
                }
            }
        }

        if (ir_func.route_info) |info| {
            mir_func.is_route = true;
            mir_func.route_method = try self.allocator.dupe(u8, info.method);
            mir_func.route_path = try self.allocator.dupe(u8, info.path);
        }

        return mir_func;
    }

    fn addCfgEdge(from: *MirBasicBlock, to: *MirBasicBlock, allocator: std.mem.Allocator) !void {
        // Add to successor list of from
        for (from.successors.items) |s| {
            if (s == to.id) return;
        }
        try from.successors.append(allocator, to.id);
        try to.predecessors.append(allocator, from.id);
    }

    fn mapValue(val: IRValue, variable_map: *const std.StringHashMap(ValueId)) MirOperand {
        return switch (val) {
            .int => |v| .{ .imm_int = v },
            .float => |v| .{ .imm_float = v },
            .string => |v| {
                if (variable_map.get(v)) |reg_id| {
                    return .{ .reg = reg_id };
                }
                return .{ .imm_str = v };
            },
            .symbol => |v| {
                if (variable_map.get(v)) |reg_id| {
                    return .{ .reg = reg_id };
                }
                return .{ .imm_str = v };
            },
            .bool => |v| .{ .imm_bool = v },
            .register => |v| .{ .reg = v },
            .label => |v| .{ .imm_int = @intCast(v) }, // Kept temporarily as instruction index
            .none => .none,
        };
    }

    fn findLabelInstructionIndex(label_id: u32, instructions: []const ir_mod.IRInstruction) ?usize {
        // Labels are emitted by the IR builder with their id in `operand1` as a
        // `.label` value (see src/ir/builder.zig). The previous lookup matched
        // `operand2.register`, which never matched, so every jump silently
        // resolved to instruction index 0 (the entry block) -> infinite loop.
        for (instructions, 0..) |instr, i| {
            if (instr.opcode == .label and instr.operand1 == .label and instr.operand1.label == label_id) {
                return i;
            }
        }
        return null;
    }

    fn lowerInstruction(self: *MirBuilder, ir_instr: ir_mod.IRInstruction, idx_to_block: *const std.AutoHashMap(usize, u32), instructions: []const ir_mod.IRInstruction, variable_map: *std.StringHashMap(ValueId), mir_func: *MirFunction, ir_func: *const IRFunction, layout: *const ModelLayout) !MirInstruction {
        _ = idx_to_block;

        if (ir_instr.opcode == .decl_var) {
            const var_name = ir_instr.operand1.string;
            var var_type: MirType = .int;
            if (ir_instr.operand2 != .none) {
                if (ir_instr.operand2 == .register) {
                    const reg_idx = ir_instr.operand2.register;
                    if (reg_idx < mir_func.val_types.items.len) {
                        var_type = mir_func.val_types.items[reg_idx];
                    }
                } else if (ir_instr.operand2 == .string or ir_instr.operand2 == .symbol) {
                    if (!variable_map.contains(ir_instr.operand2.string)) {
                        var_type = .string;
                    }
                }
            }
            if (ir_instr.operand3 == .string) {
                var_type = mapType(IRType.fromString(ir_instr.operand3.string));
            }
            const reg_id = try mir_func.addRegister(self.allocator, var_type);
            try variable_map.put(var_name, reg_id);

            if (ir_instr.operand2 != .none) {
                const init_val = mapValue(ir_instr.operand2, variable_map);
                return MirInstruction{
                    .opcode = .copy,
                    .dest = reg_id,
                    .op1 = init_val,
                };
            }
            return .{ .opcode = .nop, .dest = null };
        }

        if (ir_instr.opcode == .load_field) {
            const field_name = fieldNameOf(ir_instr.operand2);
            const obj_val = ir_instr.operand1;
            const offset = self.resolveFieldOffset(ir_func, obj_val, field_name, layout) orelse return error.UnresolvedField;
            return MirInstruction{
                .opcode = .load_field,
                .dest = ir_instr.dest,
                .op1 = mapValue(obj_val, variable_map),
                .op2 = .{ .imm_int = offset },
            };
        }

        if (ir_instr.opcode == .store_field) {
            const field_name = fieldNameOf(ir_instr.operand2);
            const obj_val = ir_instr.operand1;
            const offset = self.resolveFieldOffset(ir_func, obj_val, field_name, layout) orelse return error.UnresolvedField;
            return MirInstruction{
                .opcode = .store_field,
                .dest = null,
                .op1 = mapValue(obj_val, variable_map),
                .op2 = .{ .imm_int = offset },
                .op3 = mapValue(ir_instr.operand3, variable_map),
            };
        }

        const opcode = switch (ir_instr.opcode) {
            .nop => MirOpcode.nop,
            .load_const => MirOpcode.copy,
            .load_var => MirOpcode.copy,
            .store_var => MirOpcode.copy,
            .decl_var => MirOpcode.nop, // Memory/register mapping is simplified
            .add => MirOpcode.add,
            .sub => MirOpcode.sub,
            .mul => MirOpcode.mul,
            .div => MirOpcode.div,
            .mod => MirOpcode.mod,
            .eq => MirOpcode.eq,
            .ne => MirOpcode.ne,
            .lt => MirOpcode.lt,
            .le => MirOpcode.le,
            .gt => MirOpcode.gt,
            .ge => MirOpcode.ge,
            .and_op => MirOpcode.and_op,
            .or_op => MirOpcode.or_op,
            .not_op => MirOpcode.not_op,
            .neg => MirOpcode.neg,
            .call => MirOpcode.call,
            .ret => MirOpcode.ret,
            .arg => MirOpcode.arg,
            .jump => MirOpcode.jmp,
            .jump_if_false => MirOpcode.jmp_if,
            .alloc => MirOpcode.arena_alloc,
            .db_get, .db_set, .db_all, .db_where => MirOpcode.db_query,
            .http_response => MirOpcode.http_write,
            else => MirOpcode.nop,
        };

        if (opcode == .nop) {
            return .{ .opcode = .nop, .dest = null };
        }

        var op1 = mapValue(ir_instr.operand1, variable_map);
        var op2 = mapValue(ir_instr.operand2, variable_map);
        const op3 = mapValue(ir_instr.operand3, variable_map);

        var dest = ir_instr.dest;
        if (ir_instr.opcode == .store_var) {
            const var_name = ir_instr.operand1.string;
            dest = variable_map.get(var_name);
            op1 = op2;
            op2 = .none;
        }

        // Resolve label values into target instruction index
        if (ir_instr.opcode == .jump) {
            if (ir_instr.operand1 == .label) {
                const idx = findLabelInstructionIndex(ir_instr.operand1.label, instructions) orelse return error.UnresolvedLabel;
                op1 = .{ .imm_int = @intCast(idx) };
            }
        } else if (ir_instr.opcode == .jump_if_false) {
            // jmp_if cond target -> in MIR: jmp_if_not cond target
            // We implement it by mapping condition to op1, target to op2
            op1 = mapValue(ir_instr.operand1, variable_map);
            if (ir_instr.operand2 == .label) {
                const idx = findLabelInstructionIndex(ir_instr.operand2.label, instructions) orelse return error.UnresolvedLabel;
                op2 = .{ .imm_int = @intCast(idx) };
            }
        }

        return MirInstruction{
            .opcode = opcode,
            .dest = dest,
            .op1 = op1,
            .op2 = op2,
            .op3 = op3,
        };
    }

    /// Extracts the field name from a load_field/store_field operand2.
    fn fieldNameOf(val: ir_mod.IRValue) []const u8 {
        return switch (val) {
            .string => |s| s,
            .symbol => |s| s,
            else => "",
        };
    }

    /// Returns the model name carried by an operand's register type, if any.
    fn modelNameOf(val: ir_mod.IRValue, ir_func: *const IRFunction) ?[]const u8 {
        return switch (val) {
            .register => |r| if (r < ir_func.register_types.items.len) switch (ir_func.register_types.items[r]) {
                .model => |m| m,
                else => null,
            } else null,
            else => null,
        };
    }

    /// Resolves the byte offset of `field` on the object in `obj_val`.
    ///
    /// The owner model is taken from (in order):
    /// 1. A qualified field name "ModelName.field",
    /// 2. The object register's IR type (`register_types` -> `.model`),
    /// 3. The global field-name -> owner map when the name is unambiguous.
    fn resolveFieldOffset(self: *MirBuilder, ir_func: *const IRFunction, obj_val: ir_mod.IRValue, field_name: []const u8, layout: *const ModelLayout) ?i32 {
        _ = self;
        var model: ?[]const u8 = modelNameOf(obj_val, ir_func);
        var field = field_name;
        if (std.mem.indexOfScalar(u8, field_name, '.')) |dot| {
            model = field_name[0..dot];
            field = field_name[dot + 1 ..];
        }
        if (model == null) model = layout.field_owners.get(field);
        if (model == null) return null;
        return layout.fieldOffset(model.?, field);
    }
};
