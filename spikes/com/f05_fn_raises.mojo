# MUST FAIL: fn is the foreign-callable contract; raising across a C boundary
# is exactly what it exists to forbid.
fn bad_callback(x: Int) raises -> Int:
    if x == 0:
        raise Error("no")
    return x


def main() raises:
    _ = bad_callback(1)
