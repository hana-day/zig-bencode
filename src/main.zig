const std = @import("std");
const testing = std.testing;

const Error = error{
    InvalidInteger,
    InvalidByteString,

    UnexpectedCharacter,
    UnexpectedToken,
    UnexpectedEnd,

    AllocatorRequired,
};

const Token = union(enum) {
    ListBegin,
    End,
    Integer: struct {
        i: usize,
        count: usize,

        pub fn slice(self: @This(), input: []const u8) []const u8 {
            return input[self.i .. self.i + self.count];
        }
    },
    ByteString: struct {
        i: usize,
        count: usize,

        pub fn slice(self: @This(), input: []const u8) []const u8 {
            return input[self.i .. self.i + self.count];
        }
    },
};

const TokenStream = struct {
    i: usize = 0,
    slice: []const u8,

    pub fn init(slice: []const u8) TokenStream {
        return TokenStream{
            .slice = slice,
        };
    }

    pub fn next(self: *@This()) Error!?Token {
        var token: ?Token = null;
        if (self.i < self.slice.len) {
            switch (self.slice[self.i]) {
                'i' => {
                    token = try self.nextInteger();
                },
                '0'...'9' => {
                    token = try self.nextByteString();
                },
                else => return Error.UnexpectedCharacter,
            }
        }
        return token;
    }

    fn readChar(self: *@This()) Error!u8 {
        if (self.i >= self.slice.len) return Error.UnexpectedEnd;
        const c = self.slice[self.i];
        self.i += 1;
        return c;
    }

    fn peekChar(self: *@This()) Error!u8 {
        if (self.i >= self.slice.len) return Error.UnexpectedEnd;
        return self.slice[self.i];
    }

    /// Read signed/unsigned integer until stop_char is detected.
    fn readInteger(self: *@This(), comptime stop_char: u8) Error!void {
        var negative = false;
        if ((try self.peekChar()) == '-') {
            self.i += 1;
            negative = true;
        }
        const digits_begin = self.i;
        while (self.i < self.slice.len) {
            switch (self.slice[self.i]) {
                '0'...'9' => {
                    self.i += 1;
                },
                stop_char => {
                    const digits_count = self.i - digits_begin;
                    if (digits_count == 0) return Error.InvalidInteger;
                    if (self.slice[digits_begin] == '0') {
                        if (negative or digits_count > 1) return Error.InvalidInteger;
                    }
                    return;
                },
                else => return Error.InvalidInteger,
            }
        }
        return Error.UnexpectedEnd;
    }

    fn nextInteger(self: *@This()) Error!?Token {
        if ((try self.readChar()) != 'i') return Error.InvalidInteger;
        const tok_begin = self.i;
        try self.readInteger('e');
        self.i += 1; // skip 'e'
        return Token{ .Integer = .{
            .i = tok_begin,
            .count = self.i - tok_begin - 1,
        } };
    }

    fn nextByteString(self: *@This()) Error!?Token {
        const len_begin = self.i;
        try self.readInteger(':');
        self.i += 1; // skip ':'
        const count = std.fmt.parseInt(usize, self.slice[len_begin .. self.i - 1], 10) catch {
            return Error.InvalidByteString;
        };
        if (self.i + count > self.slice.len) {
            return Error.UnexpectedEnd;
        }
        const tok_begin = self.i;
        self.i += count;
        return Token{ .ByteString = .{
            .i = tok_begin,
            .count = count,
        } };
    }
};

fn ParseError(comptime T: type) type {
    switch (@typeInfo(T)) {
        .Int, .ComptimeInt => {
            return Error || std.fmt.ParseIntError;
        },
        .Array => {
            return Error;
        },
        .Pointer => {
            return Error || std.mem.Allocator.Error;
        },
        else => return error{},
    }
    unreachable;
}

pub const ParseOptions = struct {
    allocator: ?std.mem.Allocator = null,
};

fn parse(comptime T: type, slice: []const u8, options: ParseOptions) ParseError(T)!T {
    var ts = TokenStream.init(slice);
    const token = (try ts.next()) orelse return Error.UnexpectedEnd;
    const r = try parseInternal(T, token, slice, options);
    errdefer parseFree(T, r, options);
    return r;
}

fn parseInternal(comptime T: type, token: Token, slice: []const u8, options: ParseOptions) ParseError(T)!T {
    switch (@typeInfo(T)) {
        .Int, .ComptimeInt => {
            switch (token) {
                .Integer => |integerToken| {
                    return std.fmt.parseInt(T, integerToken.slice(slice), 10);
                },
                else => return Error.UnexpectedToken,
            }
        },
        .Array => |arrayInfo| {
            switch (token) {
                .ByteString => |byteStringToken| {
                    if (arrayInfo.child != u8) return Error.UnexpectedToken;
                    var r: T = undefined;
                    std.mem.copy(u8, &r, byteStringToken.slice(slice));
                    return r;
                },
                else => return Error.UnexpectedToken,
            }
        },
        .Pointer => |ptrInfo| {
            const allocator = options.allocator orelse return Error.AllocatorRequired;
            switch (ptrInfo.size) {
                .Slice => {
                    switch (token) {
                        .ByteString => |byteStringToken| {
                            if (ptrInfo.child != u8) return Error.UnexpectedToken;
                            const source_slice = byteStringToken.slice(slice);
                            const len = byteStringToken.count;
                            const output = try allocator.alloc(u8, len + @boolToInt(ptrInfo.sentinel != null));
                            errdefer allocator.free(output);
                            std.mem.copy(u8, output, source_slice);
                            if (ptrInfo.sentinel) |some| {
                                const char = @ptrCast(*const u8, some).*;
                                output[len] = char;
                                return output[0..len :char];
                            }

                            return output;
                        },
                        else => return Error.UnexpectedToken,
                    }
                },
                else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
            }
        },

        else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
    }
}

fn parseFree(comptime T: type, value: T, options: ParseOptions) void {
    switch (@typeInfo(T)) {
        .Int, .ComptimeInt => {},
        .Array => |arrayInfo| {
            for (value) |v| {
                parseFree(arrayInfo.child, v, options);
            }
        },
        .Pointer => |ptrInfo| {
            const allocator = options.allocator orelse unreachable;
            switch (ptrInfo.size) {
                .One => {
                    parseFree(ptrInfo.child, value.*, options);
                    allocator.destroy(value);
                },
                .Slice => {
                    for (value) |v| {
                        parseFree(ptrInfo.child, v, options);
                    }
                    allocator.free(value);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "tokenize" {
    {
        var ts = TokenStream.init("i1e");
        const token = try ts.next();
        try testing.expect(token.? == Token.Integer);
        try testing.expectEqualStrings("1", token.?.Integer.slice(ts.slice));
    }
    {
        var ts = TokenStream.init("4:spam");
        const token = try ts.next();
        try testing.expect(token.? == Token.ByteString);
        try testing.expectEqualStrings("spam", token.?.ByteString.slice(ts.slice));
    }
}

test "parsing" {
    {
        try testing.expect(0 == (try parse(u8, "i0e", .{})));
        try testing.expect(1 == (try parse(u8, "i1e", .{})));
        try testing.expect(255 == (try parse(u8, "i255e", .{})));
        try testing.expect(-1 == (try parse(i8, "i-1e", .{})));
        try testing.expect(-127 == (try parse(i8, "i-127e", .{})));

        try testing.expectError(Error.InvalidInteger, parse(u8, "ie", .{}));
        try testing.expectError(Error.InvalidInteger, parse(u8, "i01e", .{}));
        try testing.expectError(Error.InvalidInteger, parse(i8, "i-e", .{}));
        try testing.expectError(Error.InvalidInteger, parse(i8, "i-0e", .{}));
        try testing.expectError(Error.UnexpectedEnd, parse(u8, "i1", .{}));
    }
    {
        try testing.expectEqual([0]u8{}, (try parse([0]u8, "0:", .{})));
        try testing.expectEqual([4]u8{ 's', 'p', 'a', 'm' }, (try parse([4]u8, "4:spam", .{})));

        try testing.expectError(Error.InvalidInteger, parse([4]u8, "01:spam", .{}));
        try testing.expectError(Error.UnexpectedEnd, parse([4]u8, "1:", .{}));
    }
    {
        const r = try parse([]const u8, "4:spam", .{ .allocator = testing.allocator });
        defer testing.allocator.free(r);
        try testing.expectEqualStrings("spam", r);
    }
}
