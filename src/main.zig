const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Type = std.builtin.Type;

const RAM = 30_000;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stderr = std.io.getStdErr().writer();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const file_path = args.next() orelse return error.NoFile;

    try stderr.print("File: {s}\n", .{file_path});

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const code = try readToEndAlloc(allocator, file.reader());

    try stderr.print("Code:\n\"{s}\"\n", .{code.items});

    const program = try parseCode(allocator, std.mem.trim(u8, code.items, " \r\n\t"));
    code.deinit();

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var result = ArrayList(u8).init(allocator);
    try runProgram(program.items, stdin, result.writer());
    try stderr.print("Result:\n\"", .{});
    try stdout.print("{s}", .{result.items});
    try stderr.print("\"\n", .{});
}

fn readToEndAlloc(allocator: Allocator, reader: anytype) !ArrayList(u8) {
    var contents = ArrayList(u8).init(allocator);
    errdefer contents.deinit();
    reader.streamUntilDelimiter(contents.writer(), '\x00', null) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };
    return contents;
}

fn runProgram(program: []const Instruction, reader: anytype, writer: anytype) !void {
    var memory = [_]u8{0} ** RAM;
    var ptr: usize = 0;
    var cursor: usize = 0;

    errdefer std.debug.print("ptr: {d};\ncursor: {d};\nmemory: {any}\n", .{ ptr, cursor, memory });

    while (cursor < program.len) : (cursor += 1) {
        const instruction = program[cursor];
        switch (instruction) {
            Instruction.next => if (ptr == RAM - 1) {
                ptr = 0;
            } else {
                ptr += 1;
            },
            Instruction.previous => if (ptr == 0) {
                ptr = RAM - 1;
            } else {
                ptr -= 1;
            },
            Instruction.plus_one => memory[ptr] = @addWithOverflow(memory[ptr], 1)[0],
            Instruction.minus_one => memory[ptr] = @subWithOverflow(memory[ptr], 1)[0],
            Instruction.output => if (@TypeOf(writer) != @TypeOf(null)) {
                try writer.writeByte(memory[ptr]);
            } else {
                return error.NoWriter;
            },
            Instruction.input => if (@TypeOf(reader) != @TypeOf(null)) {
                memory[ptr] = try reader.readByte();
            } else {
                return error.NoReader;
            },
            Instruction.loop_forwards => |end| if (memory[ptr] == 0) {
                cursor = end;
            },
            Instruction.loop_backwards => |start| if (memory[ptr] != 0) {
                cursor = start;
            },
        }
    }
}

fn parseCode(allocator: Allocator, code: []const u8) !ArrayList(Instruction) {
    var program = ArrayList(Instruction).init(allocator);
    errdefer program.deinit();
    var loop_start_stack = ArrayList(usize).init(allocator);
    defer loop_start_stack.deinit();
    for (code, 0..) |c, i| {
        switch (c) {
            '>' => try program.append(Instruction.next),
            '<' => try program.append(Instruction.previous),
            '+' => try program.append(Instruction.plus_one),
            '-' => try program.append(Instruction.minus_one),
            '.' => try program.append(Instruction.output),
            ',' => try program.append(Instruction.input),
            '[' => try program.append(.{ .loop_forwards = blk: {
                for (i + 1..code.len) |j| {
                    if (code[j] == ']') {
                        try loop_start_stack.append(i);
                        break :blk j;
                    }
                }
                return error.InvalidLoop;
            } }),
            ']' => try program.append(.{ .loop_backwards = loop_start_stack.popOrNull() orelse return error.InvalidLoop }),
            else => {},
        }
    }
    return program;
}

const Instruction = union(enum) {
    next,
    previous,
    plus_one,
    minus_one,
    output,
    input,
    loop_forwards: usize,
    loop_backwards: usize,
};

test "hello world" {
    var code = blk: {
        const path = "./examples/hello_world.b";
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var data = ArrayList(u8).init(std.testing.allocator);
        errdefer data.deinit();
        file.reader().streamUntilDelimiter(data.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };
        break :blk data;
    };
    defer code.deinit();
    const program = try parseCode(std.testing.allocator, std.mem.trim(u8, code.items, " \r\n\t"));
    defer program.deinit();
    var output = ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try runProgram(program.items, null, output.writer());
    try std.testing.expectEqualSlices(u8, "Hello World!", output.items);
}
