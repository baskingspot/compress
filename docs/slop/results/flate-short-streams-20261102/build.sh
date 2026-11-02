#!/bin/bash
# build.sh COMPRESS_DIR OUT
set -e
MAINDIR=${MAINDIR:-/tmp/infl}
d=$(mktemp -d /tmp/infl/b.XXXX)
cp $MAINDIR/build.zig $MAINDIR/main.zig $d/
cat > $d/build.zig.zon <<ZON
.{ .name = .infl, .version = "0.0.0", .fingerprint = 0x528060edd4713f6c, .minimum_zig_version = "0.16.0",
   .dependencies = .{ .compress = .{ .path = "$(realpath --relative-to=$d $1)" } }, .paths = .{""} }
ZON
cd $d && zig build -Dtarget=native 2>&1 | grep -v "^$" | head -20
cp zig-out/bin/infl $2
