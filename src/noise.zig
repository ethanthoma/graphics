const std = @import("std");

pub const Noise = struct {
    const perm = [_]u8{ 151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180 };

    pub fn init(seed: u64) Noise {
        _ = seed;
        return Noise{};
    }

    pub fn noise2d(x: f32, y: f32) f32 {
        const xi: i32 = @intFromFloat(@floor(x));
        const yi: i32 = @intFromFloat(@floor(y));

        const xf = x - @floor(x);
        const yf = y - @floor(y);

        const u = smooth(xf);
        const v = smooth(yf);

        const x0 = @as(u8, @intCast(xi & 255));
        const y0 = @as(u8, @intCast(yi & 255));
        const x1 = @as(u8, @intCast((xi + 1) & 255));
        const y1 = @as(u8, @intCast((yi + 1) & 255));

        const gi00 = perm[(x0 +% perm[y0]) & 255] % 8;
        const gi01 = perm[(x0 +% perm[y1]) & 255] % 8;
        const gi10 = perm[(x1 +% perm[y0]) & 255] % 8;
        const gi11 = perm[(x1 +% perm[y1]) & 255] % 8;

        const n00 = dot(grad2[gi00], xf, yf);
        const n10 = dot(grad2[gi10], xf - 1, yf);
        const n01 = dot(grad2[gi01], xf, yf - 1);
        const n11 = dot(grad2[gi11], xf - 1, yf - 1);

        const nx0 = lerp(n00, n10, u);
        const nx1 = lerp(n01, n11, u);
        const nxy = lerp(nx0, nx1, v);

        return (nxy + 1) * 0.5;
    }

    pub fn octaves2d(self: Noise, x: f32, y: f32, octaves: u32, persistence: f32) f32 {
        _ = self;
        var total: f32 = 0;
        var frequency: f32 = 1;
        var amplitude: f32 = 1;
        var max_value: f32 = 0;

        var i: u32 = 0;
        while (i < octaves) : (i += 1) {
            total += noise2d(x * frequency, y * frequency) * amplitude;
            max_value += amplitude;
            amplitude *= persistence;
            frequency *= 2;
        }

        return total / max_value;
    }
};

const grad2 = [_][2]f32{
    .{ 1, 1 }, .{ -1, 1 }, .{ 1, -1 }, .{ -1, -1 },
    .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 },  .{ 0, -1 },
};

fn smooth(t: f32) f32 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + t * (b - a);
}

fn dot(grad: [2]f32, x: f32, y: f32) f32 {
    return grad[0] * x + grad[1] * y;
}
