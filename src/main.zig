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

    pub fn nextInteger(self: *@This()) Error!?Token {
        self.i += 1; // skip 'i'
        const tok_i = self.i;
        while (self.i < self.slice.len) {
            switch (self.slice[self.i]) {
                '0'...'9' => {
                    self.i += 1;
                },
                'e' => {
                    self.i += 1;
                    const count = self.i - tok_i - 1;
                    if (count > 1 and self.slice[tok_i] == '0') return Error.InvalidInteger;
                    if (count == 0) return Error.InvalidInteger;
                    return Token{ .Integer = .{
                        .i = tok_i,
                        .count = count,
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

    try testing.expectError(Error.InvalidInteger, parse(u8, "ie"));
    try testing.expectError(Error.InvalidInteger, parse(u8, "i01e"));
    try testing.expectError(Error.UnexpectedEnd, parse(u8, "i1"));
}
