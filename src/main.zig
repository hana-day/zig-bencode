const std = @import("std");
const testing = std.testing;

const Error = error{
    InvalidInteger,
    InvalidCharacter,
    UnexpectedToken,
    UnexpectedEnd,
};

const Token = union(enum) { Integer: struct {
    i: usize,
    count: usize,

    pub fn slice(self: @This(), input: []const u8) []const u8 {
        return input[self.i .. self.i + self.count];
    }
} };

const TokenStream = struct {
    i: usize = 0,
    slice: []const u8,

    pub fn init(slice: []const u8) TokenStream {
        return TokenStream{
            .slice = slice,
        };
    }

    pub fn next(self: *@This()) Error!?Token {
        if (self.i < self.slice.len) {
            switch (self.slice[self.i]) {
                'i' => return self.nextInteger(),
                else => return Error.InvalidCharacter,
            }
        }
        return null;
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

    fn nextInteger(self: *@This()) Error!?Token {
        if ((try self.readChar()) != 'i') return Error.InvalidInteger;
        const tok_begin = self.i;
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
                'e' => {
                    const digits_count = self.i - digits_begin;
                    if (digits_count == 0) return Error.InvalidInteger;
                    if (self.slice[digits_begin] == '0') {
                        if (negative or digits_count > 1) return Error.InvalidInteger;
                    }
                    self.i += 1;
                    return Token{ .Integer = .{
                        .i = tok_begin,
                        .count = self.i - tok_begin - 1,
                    } };
                },
                else => return Error.InvalidInteger,
            }
        }
        return null;
    }
};

fn ParseError(comptime T: type) type {
    switch (@typeInfo(T)) {
        .Int, .ComptimeInt => {
            return Error || std.fmt.ParseIntError;
        },
        else => return error{},
    }
    unreachable;
}

fn parse(comptime T: type, slice: []const u8) ParseError(T)!T {
    var ts = TokenStream.init(slice);
    const token = (try ts.next()) orelse return Error.UnexpectedEnd;
    switch (@typeInfo(T)) {
        .Int, .ComptimeInt => {
            switch (token) {
                .Integer => |integerToken| {
                    return std.fmt.parseInt(T, integerToken.slice(slice), 10);
                },
            }
        },
        else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
    }
    unreachable;
}

test "tokenize" {
    var ts = TokenStream.init("i1e");
    const token = try ts.next();
    try testing.expect(token.? == Token.Integer);
    try testing.expectEqualStrings("1", token.?.Integer.slice(ts.slice));
}

test "parsing" {
    try testing.expect(0 == (try parse(u8, "i0e")));
    try testing.expect(1 == (try parse(u8, "i1e")));
    try testing.expect(255 == (try parse(u8, "i255e")));
    try testing.expect(-1 == (try parse(i8, "i-1e")));
    try testing.expect(-127 == (try parse(i8, "i-127e")));

    try testing.expectError(Error.InvalidInteger, parse(u8, "ie"));
    try testing.expectError(Error.InvalidInteger, parse(u8, "i01e"));
    try testing.expectError(Error.InvalidInteger, parse(i8, "i-e"));
    try testing.expectError(Error.InvalidInteger, parse(i8, "i-0e"));
    try testing.expectError(Error.UnexpectedEnd, parse(u8, "i1"));
}
