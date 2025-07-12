const std = @import("std");

// -- Output Parameters -- //

/// Returns the return type of a given function.
pub fn getReturnType(comptime @"fn": anytype) type {
    return @typeInfo(@TypeOf(@"fn")).@"fn".return_type.?;
}

/// Returns the return type of a given function.
pub fn getLastParameterPointerType(comptime @"fn": anytype) type {
    const ti = @typeInfo(@TypeOf(@"fn")).@"fn";
    return @typeInfo(ti.params[ti.params.len - 1].type.?).pointer.child;
}

/// Returns the return type of a given function.
pub fn getLastParameterPointerTypeUnNulled(comptime @"fn": anytype) type {
    const ti = @typeInfo(@TypeOf(@"fn")).@"fn";
    return @typeInfo(@typeInfo(ti.params[ti.params.len - 1].type.?).pointer.child).optional.child;
}

/// Invokes a function pointer with the supplied arguments where the last of the
/// parameters is a output pointer to `Target`. Extracts the value of target
/// and compares the return value the function against `Success`, throwing an
/// error if they do not match.
pub fn callC(
    comptime @"fn": anytype,
    comptime success: getReturnType(@"fn"),
    args: anytype,
) !getLastParameterPointerType(@"fn") {
    const Fn = @typeInfo(@TypeOf(@"fn")).@"fn";

    var out: getLastParameterPointerType(@"fn") = undefined;
    const ret: Fn.return_type.? = @call(.auto, @"fn", args ++ .{@as(Fn.params[Fn.params.len - 1].type.?, @ptrCast(&out))});

    if (ret == success) {
        return out;
    } else {
        return error.Failure;
    }
}

/// Same as `callC` but also errors if the output is null. Expects the outpoint
/// pointer type to be nullable.
pub fn callC4(
    comptime @"fn": anytype,
    comptime success: getReturnType(@"fn"),
    args: anytype,
) !getLastParameterPointerTypeUnNulled(@"fn") {
    const Fn = @typeInfo(@TypeOf(@"fn")).@"fn";

    var out: getLastParameterPointerType(@"fn") = undefined;
    const ret: Fn.return_type.? = @call(.auto, @"fn", args ++ .{@as(Fn.params[Fn.params.len - 1].type.?, @ptrCast(&out))});

    if (ret != success or out == null) {
        return error.Failure;
    } else {
        return out.?;
    }
}

fn testFn(x: *usize, y: bool, z: [*c]?*usize) isize {
    if (y) z.* = x else z.* = null;
    return 0;
}

// Tests

test "extract final output param" {
    var x: usize = 2;
    const out = try callC4(testFn, 0, .{ &x, true });
    try std.testing.expectEqual(out.*, 2);
}

// --- //
