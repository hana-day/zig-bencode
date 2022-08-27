const std = @import("std");
const testing = std.testing;

const InternalParseError = error{
    InvalidInteger,
    InvalidByteString,

    UnexpectedCharacter,
    UnexpectedToken,
    UnexpectedEnd,

    AllocatorRequired,
};

const Error = InternalParseError || std.fmt.ParseIntError || std.mem.Allocator.Error;

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
                'l' => {
                    token = Token{ .ListBegin = .{} };
                    self.i += 1;
                },
                'e' => {
                    token = Token{ .End = .{} };
                    self.i += 1;
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

pub const ParseOptions = struct {
    allocator: ?std.mem.Allocator = null,
};

fn parse(comptime T: type, slice: []const u8, options: ParseOptions) Error!T {
    var tokenStream = TokenStream.init(slice);
    const token = (try tokenStream.next()) orelse return Error.UnexpectedEnd;
    const r = try parseInternal(T, token, &tokenStream, slice, options);
    errdefer parseFree(T, r, options);
    return r;
}

fn parseInternal(comptime T: type, token: Token, tokenStream: *TokenStream, slice: []const u8, options: ParseOptions) Error!T {
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
                .ListBegin => {
                    var r: T = undefined;
                    var i: usize = 0;
                    errdefer {
                        if (r.len > 0) while (true) : (i -= 1) {
                            if (i == r.len) continue;
                            parseFree(arrayInfo.child, r[i], options);
                            if (i == 0) break;
                        };
                    }
                    while (i < r.len) : (i += 1) {
                        const tok = (try tokenStream.next()) orelse return Error.UnexpectedEnd;
                        r[i] = try parseInternal(arrayInfo.child, tok, tokenStream, slice, options);
                    }
                    const tok = (try tokenStream.next()) orelse return Error.UnexpectedEnd;
                    switch (tok) {
                        .End => {
                            return r;
                        },
                        else => return Error.UnexpectedToken,
                    }
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
                            return output;
                        },
                        .ListBegin => {
                            var arraylist = std.ArrayList(ptrInfo.child).init(allocator);
                            errdefer {
                                while (arraylist.popOrNull()) |v| {
                                    parseFree(ptrInfo.child, v, options);
                                }
                                arraylist.deinit();
                            }
                            while (true) {
                                const tok = (try tokenStream.next()) orelse return Error.UnexpectedEnd;
                                switch (tok) {
                                    .End => break,
                                    else => {},
                                }
                                try arraylist.ensureUnusedCapacity(1);
                                const v = try parseInternal(ptrInfo.child, tok, tokenStream, slice, options);
                                arraylist.appendAssumeCapacity(v);
                            }
                            return arraylist.toOwnedSlice();
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
    {
        var ts = TokenStream.init("li1ee");
        try testing.expect((try ts.next()).? == Token.ListBegin);
        const token = try ts.next();
        try testing.expect(token.? == Token.Integer);
        try testing.expectEqualStrings("1", token.?.Integer.slice(ts.slice));
        try testing.expect((try ts.next()).? == Token.End);
    }
}

test "parsing integer" {
    try testing.expect(0 == (try parse(u8, "i0e", .{})));
    try testing.expect(1 == (try parse(u8, "i1e", .{})));
    try testing.expect(255 == (try parse(u8, "i255e", .{})));
    try testing.expect(-1 == (try parse(i8, "i-1e", .{})));
    try testing.expect(-127 == (try parse(i8, "i-127e", .{})));
}

test "parsing invalid integer" {
    try testing.expectError(Error.InvalidInteger, parse(u8, "ie", .{}));
    try testing.expectError(Error.InvalidInteger, parse(u8, "i01e", .{}));
    try testing.expectError(Error.InvalidInteger, parse(i8, "i-e", .{}));
    try testing.expectError(Error.InvalidInteger, parse(i8, "i-0e", .{}));
    try testing.expectError(Error.UnexpectedEnd, parse(u8, "i1", .{}));
}

test "parsing byte string" {
    {
        try testing.expectEqual([0]u8{}, (try parse([0]u8, "0:", .{})));
        try testing.expectEqual([4]u8{ 's', 'p', 'a', 'm' }, (try parse([4]u8, "4:spam", .{})));
    }
    {
        const r = try parse([]const u8, "4:spam", .{ .allocator = testing.allocator });
        defer testing.allocator.free(r);
        try testing.expectEqualStrings("spam", r);
    }
}

test "parsing invalid byte string" {
    try testing.expectError(Error.InvalidInteger, parse([4]u8, "01:spam", .{}));
    try testing.expectError(Error.UnexpectedEnd, parse([4]u8, "1:", .{}));
}

test "parsing list" {
    {
        const r = try parse([]const u8, "le", .{ .allocator = testing.allocator });
        defer testing.allocator.free(r);
    }
    {
        const r = try parse([]const u8, "li0ei255ee", .{ .allocator = testing.allocator });
        defer testing.allocator.free(r);
        try testing.expect(2 == r.len);
        try testing.expect(0 == r[0]);
        try testing.expect(255 == r[1]);
    }
    {
        const r = try parse([][]const u8, "l4:spam3:egge", .{ .allocator = testing.allocator });
        defer {
            for (r) |child| {
                testing.allocator.free(child);
            }
            testing.allocator.free(r);
        }
        try testing.expect(2 == r.len);
        try testing.expectEqualStrings("spam", r[0]);
        try testing.expectEqualStrings("egg", r[1]);
    }
    {
        const r = try parse([2]u8, "li0ei255ee", .{});
        try testing.expect(0 == r[0]);
        try testing.expect(255 == r[1]);
    }
}

test "parsing invalid list" {
    try testing.expectError(Error.UnexpectedEnd, parse([2]u8, "l", .{}));
    try testing.expectError(Error.UnexpectedEnd, parse([2]u8, "li", .{}));
    try testing.expectError(Error.UnexpectedEnd, parse([2]u8, "li0ei255e", .{}));
}
