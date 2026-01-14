//! CharString Type 2 interpreter for CFF fonts.
//!
//! CharString is a stack-based bytecode format for describing glyph outlines.
//! It uses cubic Bezier curves (unlike TrueType's quadratic curves).
//!
//! The interpreter maintains:
//! - Operand stack (max 48 elements)
//! - Current drawing position (x, y)
//! - Hint stem counts (for hintmask byte counting)
//! - Output contours and edges

const std = @import("std");
const Allocator = std.mem.Allocator;

const index_mod = @import("index.zig");
const Index = index_mod.Index;

const math = @import("../generator/math.zig");
const Vec2 = math.Vec2;

const edge_mod = @import("../generator/edge.zig");
const EdgeSegment = edge_mod.EdgeSegment;
const LinearSegment = edge_mod.LinearSegment;
const CubicSegment = edge_mod.CubicSegment;

const contour_mod = @import("../generator/contour.zig");
const Contour = contour_mod.Contour;
const Shape = contour_mod.Shape;

/// CharString Type 2 operators.
pub const Operator = enum(u8) {
    // Path construction
    hstem = 1,
    vstem = 3,
    vmoveto = 4,
    rlineto = 5,
    hlineto = 6,
    vlineto = 7,
    rrcurveto = 8,
    callsubr = 10,
    @"return" = 11,
    escape = 12, // Two-byte operator prefix
    endchar = 14,
    hstemhm = 18,
    hintmask = 19,
    cntrmask = 20,
    rmoveto = 21,
    hmoveto = 22,
    vstemhm = 23,
    rcurveline = 24,
    rlinecurve = 25,
    vvcurveto = 26,
    hhcurveto = 27,
    callgsubr = 29,
    vhcurveto = 30,
    hvcurveto = 31,
    _,
};

/// Two-byte operators (prefixed by 12).
pub const EscapedOperator = enum(u8) {
    flex = 35,
    hflex = 34,
    hflex1 = 36,
    flex1 = 37,
    _,
};

/// Errors specific to CharString interpretation.
pub const CharStringError = error{
    StackOverflow,
    StackUnderflow,
    InvalidOperator,
    SubroutineCallTooDeep,
    InvalidSubroutineIndex,
    UnterminatedCharString,
    OutOfMemory,
};

/// Maximum operand stack size per CFF spec.
const MAX_STACK = 48;
/// Maximum subroutine call depth per CFF spec.
const MAX_CALL_DEPTH = 10;

/// CharString Type 2 interpreter.
pub const Interpreter = struct {
    allocator: Allocator,

    // Operand stack
    stack: [MAX_STACK]f64 = undefined,
    stack_top: usize = 0,

    // Current drawing position
    x: f64 = 0,
    y: f64 = 0,

    // Whether we're in the middle of a path
    path_started: bool = false,
    // Start point of current contour (for closing)
    contour_start_x: f64 = 0,
    contour_start_y: f64 = 0,

    // Hint counting for hintmask/cntrmask
    num_h_stems: u16 = 0,
    num_v_stems: u16 = 0,
    hints_finished: bool = false,

    // Width (first operand if odd number before first path operator)
    width_parsed: bool = false,
    glyph_width: f64 = 0,
    default_width_x: f64 = 0,
    nominal_width_x: f64 = 0,

    // Subroutine context
    global_subrs: ?Index = null,
    local_subrs: ?Index = null,
    call_depth: u8 = 0,

    // Output
    contours: std.ArrayList(Contour),
    current_edges: std.ArrayList(EdgeSegment),

    pub fn init(allocator: Allocator) Interpreter {
        return .{
            .allocator = allocator,
            .contours = std.ArrayList(Contour).init(allocator),
            .current_edges = std.ArrayList(EdgeSegment).init(allocator),
        };
    }

    pub fn deinit(self: *Interpreter) void {
        // Free any edges in current_edges that weren't finalized
        self.current_edges.deinit();

        // Free all contours
        for (self.contours.items) |*c| {
            c.deinit();
        }
        self.contours.deinit();
    }

    /// Interpret a CharString and return the resulting Shape.
    pub fn interpret(
        self: *Interpreter,
        charstring: []const u8,
        global_subrs: ?Index,
        local_subrs: ?Index,
        default_width: f64,
        nominal_width: f64,
    ) CharStringError!Shape {
        self.global_subrs = global_subrs;
        self.local_subrs = local_subrs;
        self.default_width_x = default_width;
        self.nominal_width_x = nominal_width;

        try self.execute(charstring);

        // Build the final shape
        return self.buildShape();
    }

    /// Execute a CharString program.
    fn execute(self: *Interpreter, data: []const u8) CharStringError!void {
        var offset: usize = 0;

        while (offset < data.len) {
            const b0 = data[offset];
            offset += 1;

            if (b0 <= 31 and b0 != 28) {
                // Operator
                const should_return = try self.executeOperator(b0, data, &offset);
                if (should_return) return;
            } else {
                // Operand (number)
                const value = try parseNumber(data, b0, &offset);
                try self.push(value);
            }
        }
    }

    /// Execute an operator. Returns true if execution should stop (endchar/return).
    fn executeOperator(self: *Interpreter, op_byte: u8, data: []const u8, offset: *usize) CharStringError!bool {
        const op: Operator = @enumFromInt(op_byte);

        switch (op) {
            .hstem, .hstemhm => {
                try self.handleStemHints(true);
            },
            .vstem, .vstemhm => {
                try self.handleStemHints(false);
            },
            .hintmask, .cntrmask => {
                // Finish any pending hints
                if (!self.hints_finished) {
                    // Remaining stack values are vstem hints
                    const vstem_count = self.stack_top / 2;
                    self.num_v_stems += @intCast(vstem_count);
                    self.clearStack();
                    self.hints_finished = true;
                }
                // Skip hint mask bytes
                const num_bytes = (self.num_h_stems + self.num_v_stems + 7) / 8;
                offset.* += num_bytes;
            },
            .rmoveto => {
                try self.checkWidth(2);
                try self.finishContour();
                const dy = try self.pop();
                const dx = try self.pop();
                self.moveTo(self.x + dx, self.y + dy);
            },
            .hmoveto => {
                try self.checkWidth(1);
                try self.finishContour();
                const dx = try self.pop();
                self.moveTo(self.x + dx, self.y);
            },
            .vmoveto => {
                try self.checkWidth(1);
                try self.finishContour();
                const dy = try self.pop();
                self.moveTo(self.x, self.y + dy);
            },
            .rlineto => {
                try self.checkWidth(0);
                while (self.stack_top >= 2) {
                    const dx = self.stack[0];
                    const dy = self.stack[1];
                    self.removeFromBottom(2);
                    try self.lineTo(self.x + dx, self.y + dy);
                }
            },
            .hlineto => {
                try self.checkWidth(0);
                var horizontal = true;
                while (self.stack_top >= 1) {
                    const d = self.stack[0];
                    self.removeFromBottom(1);
                    if (horizontal) {
                        try self.lineTo(self.x + d, self.y);
                    } else {
                        try self.lineTo(self.x, self.y + d);
                    }
                    horizontal = !horizontal;
                }
            },
            .vlineto => {
                try self.checkWidth(0);
                var vertical = true;
                while (self.stack_top >= 1) {
                    const d = self.stack[0];
                    self.removeFromBottom(1);
                    if (vertical) {
                        try self.lineTo(self.x, self.y + d);
                    } else {
                        try self.lineTo(self.x + d, self.y);
                    }
                    vertical = !vertical;
                }
            },
            .rrcurveto => {
                try self.checkWidth(0);
                while (self.stack_top >= 6) {
                    const dx1 = self.stack[0];
                    const dy1 = self.stack[1];
                    const dx2 = self.stack[2];
                    const dy2 = self.stack[3];
                    const dx3 = self.stack[4];
                    const dy3 = self.stack[5];
                    self.removeFromBottom(6);

                    const x1 = self.x + dx1;
                    const y1 = self.y + dy1;
                    const x2 = x1 + dx2;
                    const y2 = y1 + dy2;
                    const x3 = x2 + dx3;
                    const y3 = y2 + dy3;

                    try self.curveTo(x1, y1, x2, y2, x3, y3);
                }
            },
            .hhcurveto => {
                try self.checkWidth(0);
                // {dy1}? {dxa dxb dyb dxc}+
                var dy1: f64 = 0;
                if (self.stack_top % 4 == 1) {
                    dy1 = self.stack[0];
                    self.removeFromBottom(1);
                }
                var first = true;
                while (self.stack_top >= 4) {
                    const dxa = self.stack[0];
                    const dxb = self.stack[1];
                    const dyb = self.stack[2];
                    const dxc = self.stack[3];
                    self.removeFromBottom(4);

                    const y_offset = if (first) dy1 else 0;
                    first = false;

                    const x1 = self.x + dxa;
                    const y1 = self.y + y_offset;
                    const x2 = x1 + dxb;
                    const y2 = y1 + dyb;
                    const x3 = x2 + dxc;
                    const y3 = y2;

                    try self.curveTo(x1, y1, x2, y2, x3, y3);
                }
            },
            .vvcurveto => {
                try self.checkWidth(0);
                // {dx1}? {dya dxb dyb dyc}+
                var dx1: f64 = 0;
                if (self.stack_top % 4 == 1) {
                    dx1 = self.stack[0];
                    self.removeFromBottom(1);
                }
                var first = true;
                while (self.stack_top >= 4) {
                    const dya = self.stack[0];
                    const dxb = self.stack[1];
                    const dyb = self.stack[2];
                    const dyc = self.stack[3];
                    self.removeFromBottom(4);

                    const x_offset = if (first) dx1 else 0;
                    first = false;

                    const x1 = self.x + x_offset;
                    const y1 = self.y + dya;
                    const x2 = x1 + dxb;
                    const y2 = y1 + dyb;
                    const x3 = x2;
                    const y3 = y2 + dyc;

                    try self.curveTo(x1, y1, x2, y2, x3, y3);
                }
            },
            .hvcurveto => {
                try self.checkWidth(0);
                try self.handleHvVhCurveto(true);
            },
            .vhcurveto => {
                try self.checkWidth(0);
                try self.handleHvVhCurveto(false);
            },
            .rcurveline => {
                try self.checkWidth(0);
                // {dxa dya dxb dyb dxc dyc}+ dxd dyd
                while (self.stack_top >= 8) {
                    const dx1 = self.stack[0];
                    const dy1 = self.stack[1];
                    const dx2 = self.stack[2];
                    const dy2 = self.stack[3];
                    const dx3 = self.stack[4];
                    const dy3 = self.stack[5];
                    self.removeFromBottom(6);

                    const x1 = self.x + dx1;
                    const y1 = self.y + dy1;
                    const x2 = x1 + dx2;
                    const y2 = y1 + dy2;
                    const x3 = x2 + dx3;
                    const y3 = y2 + dy3;

                    try self.curveTo(x1, y1, x2, y2, x3, y3);
                }
                // Final line
                if (self.stack_top >= 2) {
                    const dx = self.stack[0];
                    const dy = self.stack[1];
                    self.removeFromBottom(2);
                    try self.lineTo(self.x + dx, self.y + dy);
                }
            },
            .rlinecurve => {
                try self.checkWidth(0);
                // {dxa dya}+ dxb dyb dxc dyc dxd dyd
                while (self.stack_top >= 8) {
                    const dx = self.stack[0];
                    const dy = self.stack[1];
                    self.removeFromBottom(2);
                    try self.lineTo(self.x + dx, self.y + dy);
                }
                // Final curve
                if (self.stack_top >= 6) {
                    const dx1 = self.stack[0];
                    const dy1 = self.stack[1];
                    const dx2 = self.stack[2];
                    const dy2 = self.stack[3];
                    const dx3 = self.stack[4];
                    const dy3 = self.stack[5];
                    self.removeFromBottom(6);

                    const x1 = self.x + dx1;
                    const y1 = self.y + dy1;
                    const x2 = x1 + dx2;
                    const y2 = y1 + dy2;
                    const x3 = x2 + dx3;
                    const y3 = y2 + dy3;

                    try self.curveTo(x1, y1, x2, y2, x3, y3);
                }
            },
            .callsubr => {
                if (self.call_depth >= MAX_CALL_DEPTH) return CharStringError.SubroutineCallTooDeep;
                const subr_idx = try self.pop();
                const local = self.local_subrs orelse return CharStringError.InvalidSubroutineIndex;
                const biased_idx = @as(i32, @intFromFloat(subr_idx)) + subrBias(local.count);
                if (biased_idx < 0 or biased_idx >= local.count) return CharStringError.InvalidSubroutineIndex;
                const subr_data = local.getObject(@intCast(biased_idx)) catch return CharStringError.InvalidSubroutineIndex;
                self.call_depth += 1;
                try self.execute(subr_data);
                self.call_depth -= 1;
            },
            .callgsubr => {
                if (self.call_depth >= MAX_CALL_DEPTH) return CharStringError.SubroutineCallTooDeep;
                const subr_idx = try self.pop();
                const global = self.global_subrs orelse return CharStringError.InvalidSubroutineIndex;
                const biased_idx = @as(i32, @intFromFloat(subr_idx)) + subrBias(global.count);
                if (biased_idx < 0 or biased_idx >= global.count) return CharStringError.InvalidSubroutineIndex;
                const subr_data = global.getObject(@intCast(biased_idx)) catch return CharStringError.InvalidSubroutineIndex;
                self.call_depth += 1;
                try self.execute(subr_data);
                self.call_depth -= 1;
            },
            .@"return" => {
                return true;
            },
            .endchar => {
                try self.checkWidth(0);
                try self.finishContour();
                return true;
            },
            .escape => {
                // Two-byte operator
                if (offset.* >= data.len) return CharStringError.InvalidOperator;
                const b1 = data[offset.*];
                offset.* += 1;
                try self.executeEscapedOperator(b1);
            },
            else => {
                // Unknown operator - skip
            },
        }

        return false;
    }

    /// Execute a two-byte escaped operator.
    fn executeEscapedOperator(self: *Interpreter, op_byte: u8) CharStringError!void {
        const op: EscapedOperator = @enumFromInt(op_byte);

        switch (op) {
            .flex => {
                // dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 dx6 dy6 fd
                if (self.stack_top < 13) return;
                // Two curves
                const dx1 = self.stack[0];
                const dy1 = self.stack[1];
                const dx2 = self.stack[2];
                const dy2 = self.stack[3];
                const dx3 = self.stack[4];
                const dy3 = self.stack[5];
                const dx4 = self.stack[6];
                const dy4 = self.stack[7];
                const dx5 = self.stack[8];
                const dy5 = self.stack[9];
                const dx6 = self.stack[10];
                const dy6 = self.stack[11];
                // fd = self.stack[12]; // flex depth, ignored

                // First curve
                var x1 = self.x + dx1;
                var y1 = self.y + dy1;
                var x2 = x1 + dx2;
                var y2 = y1 + dy2;
                var x3 = x2 + dx3;
                var y3 = y2 + dy3;
                try self.curveTo(x1, y1, x2, y2, x3, y3);

                // Second curve
                x1 = self.x + dx4;
                y1 = self.y + dy4;
                x2 = x1 + dx5;
                y2 = y1 + dy5;
                x3 = x2 + dx6;
                y3 = y2 + dy6;
                try self.curveTo(x1, y1, x2, y2, x3, y3);

                self.clearStack();
            },
            .hflex => {
                // dx1 dx2 dy2 dx3 dx4 dx5 dx6
                if (self.stack_top < 7) return;
                const dx1 = self.stack[0];
                const dx2 = self.stack[1];
                const dy2 = self.stack[2];
                const dx3 = self.stack[3];
                const dx4 = self.stack[4];
                const dx5 = self.stack[5];
                const dx6 = self.stack[6];

                // First curve
                var x1 = self.x + dx1;
                var y1 = self.y;
                var x2 = x1 + dx2;
                var y2 = y1 + dy2;
                var x3 = x2 + dx3;
                var y3 = y2;
                try self.curveTo(x1, y1, x2, y2, x3, y3);

                // Second curve
                x1 = self.x + dx4;
                y1 = self.y;
                x2 = x1 + dx5;
                y2 = y1 - dy2; // Symmetric
                x3 = x2 + dx6;
                y3 = y2 + dy2; // Back to original y
                try self.curveTo(x1, y1, x2, y2, x3, y3);

                self.clearStack();
            },
            .hflex1 => {
                // dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
                if (self.stack_top < 9) return;
                const dx1 = self.stack[0];
                const dy1 = self.stack[1];
                const dx2 = self.stack[2];
                const dy2 = self.stack[3];
                const dx3 = self.stack[4];
                const dx4 = self.stack[5];
                const dx5 = self.stack[6];
                const dy5 = self.stack[7];
                const dx6 = self.stack[8];

                const start_y = self.y;

                // First curve
                var x1 = self.x + dx1;
                var y1 = self.y + dy1;
                var x2 = x1 + dx2;
                var y2 = y1 + dy2;
                var x3 = x2 + dx3;
                var y3 = y2;
                try self.curveTo(x1, y1, x2, y2, x3, y3);

                // Second curve
                x1 = self.x + dx4;
                y1 = self.y;
                x2 = x1 + dx5;
                y2 = y1 + dy5;
                x3 = x2 + dx6;
                y3 = start_y; // Back to original y
                try self.curveTo(x1, y1, x2, y2, x3, y3);

                self.clearStack();
            },
            .flex1 => {
                // dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 d6
                if (self.stack_top < 11) return;
                const dx1 = self.stack[0];
                const dy1 = self.stack[1];
                const dx2 = self.stack[2];
                const dy2 = self.stack[3];
                const dx3 = self.stack[4];
                const dy3 = self.stack[5];
                const dx4 = self.stack[6];
                const dy4 = self.stack[7];
                const dx5 = self.stack[8];
                const dy5 = self.stack[9];
                const d6 = self.stack[10];

                const start_x = self.x;
                const start_y = self.y;

                // First curve
                var x1 = self.x + dx1;
                var y1 = self.y + dy1;
                var x2 = x1 + dx2;
                var y2 = y1 + dy2;
                var x3 = x2 + dx3;
                var y3 = y2 + dy3;
                try self.curveTo(x1, y1, x2, y2, x3, y3);

                // Second curve - determine if d6 is dx or dy
                x1 = self.x + dx4;
                y1 = self.y + dy4;
                x2 = x1 + dx5;
                y2 = y1 + dy5;

                const abs_dx = @abs(x2 - start_x);
                const abs_dy = @abs(y2 - start_y);
                if (abs_dx > abs_dy) {
                    x3 = x2 + d6;
                    y3 = start_y;
                } else {
                    x3 = start_x;
                    y3 = y2 + d6;
                }
                try self.curveTo(x1, y1, x2, y2, x3, y3);

                self.clearStack();
            },
            else => {},
        }
    }

    /// Handle stem hint operators (hstem, vstem, hstemhm, vstemhm).
    fn handleStemHints(self: *Interpreter, is_horizontal: bool) CharStringError!void {
        try self.checkWidth(0);
        const count = self.stack_top / 2;
        if (is_horizontal) {
            self.num_h_stems += @intCast(count);
        } else {
            self.num_v_stems += @intCast(count);
        }
        self.clearStack();
    }

    /// Handle hvcurveto and vhcurveto operators.
    fn handleHvVhCurveto(self: *Interpreter, start_horizontal: bool) CharStringError!void {
        var horizontal = start_horizontal;

        while (self.stack_top >= 4) {
            const is_last = self.stack_top < 8;
            const has_final_d = is_last and (self.stack_top == 5);

            if (horizontal) {
                // dx1 dx2 dy2 dy3 {dx3}?
                const dx1 = self.stack[0];
                const dx2 = self.stack[1];
                const dy2 = self.stack[2];
                const dy3 = self.stack[3];
                const dx3 = if (has_final_d) self.stack[4] else 0;
                self.removeFromBottom(if (has_final_d) @as(usize, 5) else @as(usize, 4));

                const x1 = self.x + dx1;
                const y1 = self.y;
                const x2 = x1 + dx2;
                const y2 = y1 + dy2;
                const x3 = x2 + dx3;
                const y3 = y2 + dy3;

                try self.curveTo(x1, y1, x2, y2, x3, y3);
            } else {
                // dy1 dx2 dy2 dx3 {dy3}?
                const dy1 = self.stack[0];
                const dx2 = self.stack[1];
                const dy2 = self.stack[2];
                const dx3 = self.stack[3];
                const dy3 = if (has_final_d) self.stack[4] else 0;
                self.removeFromBottom(if (has_final_d) @as(usize, 5) else @as(usize, 4));

                const x1 = self.x;
                const y1 = self.y + dy1;
                const x2 = x1 + dx2;
                const y2 = y1 + dy2;
                const x3 = x2 + dx3;
                const y3 = y2 + dy3;

                try self.curveTo(x1, y1, x2, y2, x3, y3);
            }

            horizontal = !horizontal;
        }
    }

    /// Check and extract width if present (odd operand count before first path op).
    fn checkWidth(self: *Interpreter, expected_args: usize) CharStringError!void {
        if (self.width_parsed) return;
        self.width_parsed = true;

        // If odd number of args, first one is width
        if (self.stack_top > expected_args and (self.stack_top - expected_args) % 2 == 1) {
            self.glyph_width = self.stack[0] + self.nominal_width_x;
            self.removeFromBottom(1);
        } else {
            self.glyph_width = self.default_width_x;
        }
    }

    // Drawing operations

    fn moveTo(self: *Interpreter, x: f64, y: f64) void {
        self.x = x;
        self.y = y;
        self.contour_start_x = x;
        self.contour_start_y = y;
        self.path_started = true;
    }

    fn lineTo(self: *Interpreter, x: f64, y: f64) CharStringError!void {
        if (!self.path_started) {
            self.moveTo(self.x, self.y);
        }

        const segment = LinearSegment.init(
            Vec2.init(self.x, self.y),
            Vec2.init(x, y),
        );
        self.current_edges.append(.{ .linear = segment }) catch return CharStringError.OutOfMemory;
        self.x = x;
        self.y = y;
    }

    fn curveTo(self: *Interpreter, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) CharStringError!void {
        if (!self.path_started) {
            self.moveTo(self.x, self.y);
        }

        const segment = CubicSegment.init(
            Vec2.init(self.x, self.y),
            Vec2.init(x1, y1),
            Vec2.init(x2, y2),
            Vec2.init(x3, y3),
        );
        self.current_edges.append(.{ .cubic = segment }) catch return CharStringError.OutOfMemory;
        self.x = x3;
        self.y = y3;
    }

    fn finishContour(self: *Interpreter) CharStringError!void {
        if (self.current_edges.items.len == 0) return;

        // Close the contour if not already closed
        const eps = 0.001;
        if (@abs(self.x - self.contour_start_x) > eps or @abs(self.y - self.contour_start_y) > eps) {
            try self.lineTo(self.contour_start_x, self.contour_start_y);
        }

        // Create contour from edges
        const edges = self.current_edges.toOwnedSlice() catch return CharStringError.OutOfMemory;
        const contour = Contour.fromEdges(self.allocator, edges);
        self.contours.append(contour) catch return CharStringError.OutOfMemory;

        self.path_started = false;
    }

    fn buildShape(self: *Interpreter) CharStringError!Shape {
        const contours = self.contours.toOwnedSlice() catch return CharStringError.OutOfMemory;
        return Shape.fromContours(self.allocator, contours);
    }

    // Stack operations

    fn push(self: *Interpreter, value: f64) CharStringError!void {
        if (self.stack_top >= MAX_STACK) return CharStringError.StackOverflow;
        self.stack[self.stack_top] = value;
        self.stack_top += 1;
    }

    fn pop(self: *Interpreter) CharStringError!f64 {
        if (self.stack_top == 0) return CharStringError.StackUnderflow;
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    fn clearStack(self: *Interpreter) void {
        self.stack_top = 0;
    }

    fn removeFromBottom(self: *Interpreter, count: usize) void {
        if (count >= self.stack_top) {
            self.stack_top = 0;
            return;
        }
        const remaining = self.stack_top - count;
        for (0..remaining) |i| {
            self.stack[i] = self.stack[i + count];
        }
        self.stack_top = remaining;
    }
};

/// Calculate subroutine bias based on count.
pub fn subrBias(count: u16) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

/// Parse a number from CharString data.
fn parseNumber(data: []const u8, b0: u8, offset: *usize) CharStringError!f64 {
    if (b0 >= 32 and b0 <= 246) {
        // Single byte: -107 to 107
        return @as(f64, @floatFromInt(@as(i16, b0) - 139));
    } else if (b0 >= 247 and b0 <= 250) {
        // Two bytes positive
        if (offset.* >= data.len) return CharStringError.InvalidOperator;
        const b1 = data[offset.*];
        offset.* += 1;
        return @floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, b1) + 108);
    } else if (b0 >= 251 and b0 <= 254) {
        // Two bytes negative
        if (offset.* >= data.len) return CharStringError.InvalidOperator;
        const b1 = data[offset.*];
        offset.* += 1;
        return @floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, b1) - 108);
    } else if (b0 == 28) {
        // Three bytes: signed i16
        if (offset.* + 2 > data.len) return CharStringError.InvalidOperator;
        const value = std.mem.readInt(i16, data[offset.*..][0..2], .big);
        offset.* += 2;
        return @floatFromInt(value);
    } else if (b0 == 255) {
        // Five bytes: 16.16 fixed point (Type 2 CharStrings)
        if (offset.* + 4 > data.len) return CharStringError.InvalidOperator;
        const value = std.mem.readInt(i32, data[offset.*..][0..4], .big);
        offset.* += 4;
        return @as(f64, @floatFromInt(value)) / 65536.0;
    }

    return CharStringError.InvalidOperator;
}

// ============================================================================
// Tests
// ============================================================================

test "subrBias" {
    try std.testing.expectEqual(@as(i32, 107), subrBias(100));
    try std.testing.expectEqual(@as(i32, 107), subrBias(1239));
    try std.testing.expectEqual(@as(i32, 1131), subrBias(1240));
    try std.testing.expectEqual(@as(i32, 1131), subrBias(33899));
    try std.testing.expectEqual(@as(i32, 32768), subrBias(33900));
}

test "parseNumber - single byte" {
    var offset: usize = 0;
    // b0 = 139 encodes 0
    try std.testing.expectApproxEqAbs(@as(f64, 0), try parseNumber(&[_]u8{}, 139, &offset), 0.001);

    // b0 = 32 encodes -107
    offset = 0;
    try std.testing.expectApproxEqAbs(@as(f64, -107), try parseNumber(&[_]u8{}, 32, &offset), 0.001);

    // b0 = 246 encodes 107
    offset = 0;
    try std.testing.expectApproxEqAbs(@as(f64, 107), try parseNumber(&[_]u8{}, 246, &offset), 0.001);
}

test "parseNumber - two bytes positive" {
    const data = [_]u8{0};
    var offset: usize = 0;
    // b0 = 247, b1 = 0 encodes 108
    try std.testing.expectApproxEqAbs(@as(f64, 108), try parseNumber(&data, 247, &offset), 0.001);
}

test "parseNumber - two bytes negative" {
    const data = [_]u8{0};
    var offset: usize = 0;
    // b0 = 251, b1 = 0 encodes -108
    try std.testing.expectApproxEqAbs(@as(f64, -108), try parseNumber(&data, 251, &offset), 0.001);
}

test "parseNumber - three bytes i16" {
    const data = [_]u8{ 0x01, 0xF4 }; // 500
    var offset: usize = 0;
    try std.testing.expectApproxEqAbs(@as(f64, 500), try parseNumber(&data, 28, &offset), 0.001);
}

test "Interpreter - simple line" {
    const allocator = std.testing.allocator;
    var interp = Interpreter.init(allocator);
    defer interp.deinit();

    // rmoveto(0, 0), rlineto(100, 0), rlineto(0, 100), rlineto(-100, 0), endchar
    // Encoded: 139 139 21  239 139 5  139 239 5  39 139 5  14
    // 139 = 0, 239 = 100, 39 = -100
    const charstring = [_]u8{
        139, 139, 21, // rmoveto 0 0
        239, 139, 5, // rlineto 100 0
        139, 239, 5, // rlineto 0 100
        39,  139, 5, // rlineto -100 0
        14, // endchar
    };

    var shape = try interp.interpret(&charstring, null, null, 0, 0);
    defer shape.deinit();

    try std.testing.expectEqual(@as(usize, 1), shape.contourCount());
    // 3 explicit lines + 1 closing line = 4 edges
    try std.testing.expectEqual(@as(usize, 4), shape.contours[0].edges.len);
}
