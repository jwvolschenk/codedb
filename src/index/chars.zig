const std = @import("std");

pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn normalizeChar(c: u8) u8 {
    // Lowercase for case-insensitive trigram matching
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
