const std = @import("std");
const testing = std.testing;

const Error = error{
    InvalidInteger,
    InvalidCharacter,
};

const Token = union(enum) { Integer: struct {
    i: usize,
    count: usize,

    pub fn slice(self: @This(), input: []const u8) []const u8 {
        return input[self.i - self.count .. self.i];
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
                    const count = self.i-tok_i-1;
                    if (self.slice[tok_i] == '0') return Error.InvalidInteger;
                    if (count == 0) return Error.InvalidInteger;
                    return Token{.Integer = .{
                        .i = tok_i,
                        .count = count,
                    }};
                },
                else => return Error.InvalidInteger,
            }
        }
        return null;
    }
};

test "tokenize" {
    var ts = TokenStream.init("i1e");
    const token = try ts.next();
    try testing.expect(token.? == Token.Integer);
    try testing.expectEqual(@intCast(usize, 1), token.?.Integer.count);
}
