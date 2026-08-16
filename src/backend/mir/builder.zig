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
            .result => .result,
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
        var pending_args = std.ArrayListUnmanaged(MirInstruction).empty;
        defer pending_args.deinit(self.allocator);

        for (ir_func.instructions.items, 0..) |ir_instr, i| {
            if (block_starts.get(i)) |_| {
                if (idx_to_block.get(i)) |bid| {
                    current_block_id = bid;
                }
            }

            // `.arg` instructions are buffered so an sret-returning call
            // (dest typed `.result`) can inject its hidden `sret_alloc`
            // BEFORE the arguments are placed (arg 0 = result pointer).
            if (ir_instr.opcode == .arg) {
                const mir_arg = try self.lowerInstruction(ir_instr, &idx_to_block, ir_func.instructions.items, &variable_map, &mir_func, ir_func, layout);
                if (mir_arg.opcode != .nop) {
                    try pending_args.append(self.allocator, mir_arg);
                }
                continue;
            }

            if (pending_args.items.len > 0) {
                const is_sret_call = ir_instr.opcode == .call and
                    ir_instr.dest != null and
                    ir_instr.dest.? < ir_func.register_types.items.len and
                    ir_func.register_types.items[ir_instr.dest.?] == .result;
                const is_arena_call = ir_instr.opcode == .call and isArenaCallName(callNameOf(ir_instr.operand1));
                if (is_sret_call) {
                    // Reserve the arena-allocated OrbitResult the callee
                    // writes through its hidden sret pointer; dest must be
                    // typed `.result` (maps to MIR `.result`).
                    try mir_func.blocks.items[current_block_id].instructions.append(self.allocator, MirInstruction{
                        .opcode = .sret_alloc,
                        .dest = ir_instr.dest,
                    });
                }
                // A callee may be BOTH sret-returning (`.result` dest) and
                // arena-requiring (e.g. `orbit_file_read`), so arena_arg is a
                // separate emission, not an `else if`. The lowering places the
                // sret buffer in ABI slot 0 and the arena in slot 1 (or slot 0
                // when no sret), with the explicit args shifted past both.
                if (is_arena_call) {
                    // Runtime functions declared to take `OrbitArena*` as their
                    // first parameter (mirroring the C backend's arena-function
                    // registry) receive orbit_global_arena as a hidden ABI arg.
                    try mir_func.blocks.items[current_block_id].instructions.append(self.allocator, MirInstruction{
                        .opcode = .arena_arg,
                        .dest = null,
                    });
                }
                for (pending_args.items) |arg_instr| {
                    try mir_func.blocks.items[current_block_id].instructions.append(self.allocator, arg_instr);
                }
                pending_args.clearRetainingCapacity();
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

    /// Extracts the callee name from a `.call` instruction's operand1.
    fn callNameOf(val: ir_mod.IRValue) ?[]const u8 {
        return switch (val) {
            .string => |s| s,
            .symbol => |s| s,
            else => null,
        };
    }

    /// Runtime functions whose first parameter is `OrbitArena*`; the C backend
    /// injects the arena at codegen (`registerArenaFunction`), the native MIR
    /// builder mirrors that with a hidden `arena_arg` before the arguments.
    fn isArenaCallName(name: ?[]const u8) bool {
        const name_ = name orelse return false;
        const arena_fns = [_][]const u8{
            "orbit_file_read",
            "orbit_file_list_dir",
            "orbit_list_create",
            "orbit_map_create",
            "orbit_response_create",
            "orbit_string_slice",
            "orbit_string_split",
            "orbit_string_replace",
            "orbit_os_exec",
            "orbit_os_env",
            "orbit_os_argv",
            "orbit_string_concat",
            "orbit_int_to_string",
            "orbit_float_to_string",
            "orbit_http_query_get",
            "orbit_http_header_get",
            "orbit_auth_bearer_token",
            "orbit_auth_role",
            "orbit_auth_current_role",
            "orbit_auth_has_role",
            "orbit_db_query_all",
            "orbit_db_query_where",
            "orbit_db_query_get",
            "orbit_http_client_fetch",
            "orbit_cache_get",
            "orbit_file_upload_save",
            "orbit_http_param_get",
            "orbit_http_body_get",
            "orbit_base64url_encode_str",
            "orbit_sha256_hex",
            "orbit_hmac_sha256_base64url",
        };
        for (arena_fns) |af| {
            if (std.mem.eql(u8, name_, af)) return true;
        }
        return false;
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
            const offset = self.resolveFieldOffset(ir_func, obj_val, field_name, layout) orelse {
                const oreg: u32 = if (obj_val == .register) obj_val.register else 9999;
                std.debug.print("UNRESOLVED load_field fn={s} field={s} obj_reg={d} regtype={s}\n", .{ ir_func.name, field_name, oreg, @tagName(if (oreg < ir_func.register_types.items.len) ir_func.register_types.items[oreg] else .unknown) });
                return error.UnresolvedField;
            };
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
            const offset = self.resolveFieldOffset(ir_func, obj_val, field_name, layout) orelse {
                std.debug.print("UNRESOLVED store_field fn={s} field={s} obj_val={s}\n", .{ ir_func.name, field_name, @tagName(obj_val) });
                return error.UnresolvedField;
            };
            return MirInstruction{
                .opcode = .store_field,
                .dest = null,
                .op1 = mapValue(obj_val, variable_map),
                .op2 = .{ .imm_int = offset },
                .op3 = mapValue(ir_instr.operand3, variable_map),
            };
        }

        // Collections: carry the IR operands straight through. The void-dest
        // results of push/set are discarded at the MIR level.
        if (ir_instr.opcode == .list_create) {
            return MirInstruction{
                .opcode = .list_create,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
                .op2 = mapValue(ir_instr.operand2, variable_map),
            };
        }
        if (ir_instr.opcode == .list_push) {
            return MirInstruction{
                .opcode = .list_push,
                .dest = null,
                .op1 = mapValue(ir_instr.operand1, variable_map),
                .op2 = mapValue(ir_instr.operand2, variable_map),
            };
        }
        if (ir_instr.opcode == .list_pop) {
            return MirInstruction{
                .opcode = .list_pop,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
            };
        }
        if (ir_instr.opcode == .list_get) {
            return MirInstruction{
                .opcode = .list_get,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
                .op2 = mapValue(ir_instr.operand2, variable_map),
            };
        }
        if (ir_instr.opcode == .list_set) {
            return MirInstruction{
                .opcode = .list_set,
                .dest = null,
                .op1 = mapValue(ir_instr.operand1, variable_map),
                .op2 = mapValue(ir_instr.operand2, variable_map),
                .op3 = mapValue(ir_instr.operand3, variable_map),
            };
        }
        if (ir_instr.opcode == .list_len) {
            return MirInstruction{
                .opcode = .list_len,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
            };
        }
        if (ir_instr.opcode == .map_create) {
            return MirInstruction{
                .opcode = .map_create,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
            };
        }
        if (ir_instr.opcode == .map_set) {
            return MirInstruction{
                .opcode = .map_set,
                .dest = null,
                .op1 = mapValue(ir_instr.operand1, variable_map),
                .op2 = mapValue(ir_instr.operand2, variable_map),
                .op3 = mapValue(ir_instr.operand3, variable_map),
            };
        }
        if (ir_instr.opcode == .map_get) {
            return MirInstruction{
                .opcode = .map_get,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
                .op2 = mapValue(ir_instr.operand2, variable_map),
            };
        }
        if (ir_instr.opcode == .map_has) {
            return MirInstruction{
                .opcode = .map_has,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
                .op2 = mapValue(ir_instr.operand2, variable_map),
            };
        }

        // Results: the register holds a pointer to an arena-allocated
        // OrbitResult; operands map straight through.
        if (ir_instr.opcode == .result_ok) {
            return MirInstruction{
                .opcode = .result_ok,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
            };
        }
        if (ir_instr.opcode == .result_err) {
            return MirInstruction{
                .opcode = .result_err,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
                .op2 = mapValue(ir_instr.operand2, variable_map),
            };
        }
        if (ir_instr.opcode == .result_unwrap) {
            return MirInstruction{
                .opcode = .result_unwrap,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
            };
        }
        if (ir_instr.opcode == .result_is_ok) {
            return MirInstruction{
                .opcode = .result_is_ok,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
            };
        }

        // Tagged unions: carry IR operands straight through. The tag operand is
        // a string like "Foo_TAG_Bar"; the native lowering resolves it to its
        // variant index via the module's type map.
        if (ir_instr.opcode == .union_create) {
            return MirInstruction{
                .opcode = .union_create,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
                .op2 = mapValue(ir_instr.operand2, variable_map),
            };
        }
        if (ir_instr.opcode == .union_get_tag) {
            return MirInstruction{
                .opcode = .union_get_tag,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
            };
        }
        if (ir_instr.opcode == .union_get_data) {
            return MirInstruction{
                .opcode = .union_get_data,
                .dest = ir_instr.dest,
                .op1 = mapValue(ir_instr.operand1, variable_map),
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
