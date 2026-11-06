//! Floating-point kernels of the standard library (RFC-0077), copied from the library of the
//! pinned toolchain (Zig 0.17.0, MIT licence; the files it ported from musl and Go carry those
//! projects' MIT and BSD licences) by `tools/vendor-math-kernels.py`. GENERATED: do not edit.
//!
//! Why a copy: `@sin`, `@exp` and their kin compile to calls of the C symbols `sin`, `exp`,
//! ..., which a build that links a C library takes from that library. Results would then
//! differ between hosts in the last place, and so would every report that prints one. The
//! copies use only IEEE-754 addition, subtraction, multiplication, division and square root,
//! which every host computes alike, so a result is a function of its argument alone.
//!
//! Each namespace holds the binary64 path of one source file, unchanged except that calls of
//! `@exp` and `@log` name the copies. Raising floating-point exceptions is compiled out.
const std = @import("std");
const math = std.math;
const mem = std.mem;
const maxInt = std.math.maxInt;
const compiler_rt = struct {
    const want_float_exceptions = false;
};
const namespaces = @This();

/// From `lib/compiler_rt/exp.zig`.
pub const exp_kernel = struct {
    pub fn exp_f64(x_: f64) f64 {
        const half = [_]f64{ 0.5, -0.5 };
        const ln2hi: f64 = 6.93147180369123816490e-01;
        const ln2lo: f64 = 1.90821492927058770002e-10;
        const invln2: f64 = 1.44269504088896338700e+00;
        const P1: f64 = 1.66666666666666019037e-01;
        const P2: f64 = -2.77777777770155933842e-03;
        const P3: f64 = 6.61375632143793436117e-05;
        const P4: f64 = -1.65339022054652515390e-06;
        const P5: f64 = 4.13813679705723846039e-08;

        var x = x_;
        const ux: u64 = @bitCast(x);
        var hx = ux >> 32;
        const sign: i32 = @intCast(hx >> 31);
        hx &= 0x7FFFFFFF;

        if (math.isNan(x)) {
            return x;
        }

        // |x| >= 708.39 or nan
        if (hx >= 0x4086232B) {
            // nan
            if (hx > 0x7FF00000) {
                return x;
            }
            if (x > 709.782712893383973096) {
                // overflow if x != inf
                return if (compiler_rt.want_float_exceptions) x * 0x1p1023 else std.math.inf(f64);
            }
            if (x < -708.39641853226410622) {
                // underflow if x != -inf
                if (compiler_rt.want_float_exceptions) mem.doNotOptimizeAway(-0x0.0000000000001p-1022 / x);
                if (x < -745.13321910194110842) {
                    return 0;
                }
            }
        }

        // argument reduction
        var k: i32 = undefined;
        var hi: f64 = undefined;
        var lo: f64 = undefined;

        // |x| > 0.5 * ln2
        if (hx > 0x3FD62E42) {
            // |x| >= 1.5 * ln2
            if (hx > 0x3FF0A2B2) {
                k = @intFromFloat(invln2 * x + half[@intCast(sign)]);
            } else {
                k = 1 - sign - sign;
            }

            const dk: f64 = @floatFromInt(k);
            hi = x - dk * ln2hi;
            lo = dk * ln2lo;
            x = hi - lo;
        }
        // |x| > 2^(-28)
        else if (hx > 0x3E300000) {
            k = 0;
            hi = x;
            lo = 0;
        } else {
            // inexact if x != 0
            if (compiler_rt.want_float_exceptions) mem.doNotOptimizeAway(0x1.0p1023 + x);
            return 1 + x;
        }

        const xx = x * x;
        const c = x - xx * (P1 + xx * (P2 + xx * (P3 + xx * (P4 + xx * P5))));
        const y = 1 + (x * c / (2 - c) - lo + hi);

        if (k == 0) {
            return y;
        } else {
            return math.scalbn(y, k);
        }
    }
};

/// From `lib/compiler_rt/log.zig`.
pub const log_kernel = struct {
    pub fn log_f64(x: f64) f64 {
        const poly1 = [_]f64{
            -0x1p-1,
            0x1.5555555555577p-2,
            -0x1.ffffffffffdcbp-3,
            0x1.999999995dd0cp-3,
            -0x1.55555556745a7p-3,
            0x1.24924a344de3p-3,
            -0x1.fffffa4423d65p-4,
            0x1.c7184282ad6cap-4,
            -0x1.999eb43b068ffp-4,
            0x1.78182f7afd085p-4,
            -0x1.5521375d145cdp-4,
        };

        const poly = [_]f64{
            -0x1.0000000000001p-1,
            0x1.555555551305bp-2,
            -0x1.fffffffeb459p-3,
            0x1.999b324f10111p-3,
            -0x1.55575e506c89fp-3,
        };

        const tab = [128]struct { invc: f64, logc: f64 }{
            .{ .invc = 0x1.734f0c3e0de9fp+0, .logc = -0x1.7cc7f79e69000p-2 },
            .{ .invc = 0x1.713786a2ce91fp+0, .logc = -0x1.76feec20d0000p-2 },
            .{ .invc = 0x1.6f26008fab5a0p+0, .logc = -0x1.713e31351e000p-2 },
            .{ .invc = 0x1.6d1a61f138c7dp+0, .logc = -0x1.6b85b38287800p-2 },
            .{ .invc = 0x1.6b1490bc5b4d1p+0, .logc = -0x1.65d5590807800p-2 },
            .{ .invc = 0x1.69147332f0cbap+0, .logc = -0x1.602d076180000p-2 },
            .{ .invc = 0x1.6719f18224223p+0, .logc = -0x1.5a8ca86909000p-2 },
            .{ .invc = 0x1.6524f99a51ed9p+0, .logc = -0x1.54f4356035000p-2 },
            .{ .invc = 0x1.63356aa8f24c4p+0, .logc = -0x1.4f637c36b4000p-2 },
            .{ .invc = 0x1.614b36b9ddc14p+0, .logc = -0x1.49da7fda85000p-2 },
            .{ .invc = 0x1.5f66452c65c4cp+0, .logc = -0x1.445923989a800p-2 },
            .{ .invc = 0x1.5d867b5912c4fp+0, .logc = -0x1.3edf439b0b800p-2 },
            .{ .invc = 0x1.5babccb5b90dep+0, .logc = -0x1.396ce448f7000p-2 },
            .{ .invc = 0x1.59d61f2d91a78p+0, .logc = -0x1.3401e17bda000p-2 },
            .{ .invc = 0x1.5805612465687p+0, .logc = -0x1.2e9e2ef468000p-2 },
            .{ .invc = 0x1.56397cee76bd3p+0, .logc = -0x1.2941b3830e000p-2 },
            .{ .invc = 0x1.54725e2a77f93p+0, .logc = -0x1.23ec58cda8800p-2 },
            .{ .invc = 0x1.52aff42064583p+0, .logc = -0x1.1e9e129279000p-2 },
            .{ .invc = 0x1.50f22dbb2bddfp+0, .logc = -0x1.1956d2b48f800p-2 },
            .{ .invc = 0x1.4f38f4734ded7p+0, .logc = -0x1.141679ab9f800p-2 },
            .{ .invc = 0x1.4d843cfde2840p+0, .logc = -0x1.0edd094ef9800p-2 },
            .{ .invc = 0x1.4bd3ec078a3c8p+0, .logc = -0x1.09aa518db1000p-2 },
            .{ .invc = 0x1.4a27fc3e0258ap+0, .logc = -0x1.047e65263b800p-2 },
            .{ .invc = 0x1.4880524d48434p+0, .logc = -0x1.feb224586f000p-3 },
            .{ .invc = 0x1.46dce1b192d0bp+0, .logc = -0x1.f474a7517b000p-3 },
            .{ .invc = 0x1.453d9d3391854p+0, .logc = -0x1.ea4443d103000p-3 },
            .{ .invc = 0x1.43a2744b4845ap+0, .logc = -0x1.e020d44e9b000p-3 },
            .{ .invc = 0x1.420b54115f8fbp+0, .logc = -0x1.d60a22977f000p-3 },
            .{ .invc = 0x1.40782da3ef4b1p+0, .logc = -0x1.cc00104959000p-3 },
            .{ .invc = 0x1.3ee8f5d57fe8fp+0, .logc = -0x1.c202956891000p-3 },
            .{ .invc = 0x1.3d5d9a00b4ce9p+0, .logc = -0x1.b81178d811000p-3 },
            .{ .invc = 0x1.3bd60c010c12bp+0, .logc = -0x1.ae2c9ccd3d000p-3 },
            .{ .invc = 0x1.3a5242b75dab8p+0, .logc = -0x1.a45402e129000p-3 },
            .{ .invc = 0x1.38d22cd9fd002p+0, .logc = -0x1.9a877681df000p-3 },
            .{ .invc = 0x1.3755bc5847a1cp+0, .logc = -0x1.90c6d69483000p-3 },
            .{ .invc = 0x1.35dce49ad36e2p+0, .logc = -0x1.87120a645c000p-3 },
            .{ .invc = 0x1.34679984dd440p+0, .logc = -0x1.7d68fb4143000p-3 },
            .{ .invc = 0x1.32f5cceffcb24p+0, .logc = -0x1.73cb83c627000p-3 },
            .{ .invc = 0x1.3187775a10d49p+0, .logc = -0x1.6a39a9b376000p-3 },
            .{ .invc = 0x1.301c8373e3990p+0, .logc = -0x1.60b3154b7a000p-3 },
            .{ .invc = 0x1.2eb4ebb95f841p+0, .logc = -0x1.5737d76243000p-3 },
            .{ .invc = 0x1.2d50a0219a9d1p+0, .logc = -0x1.4dc7b8fc23000p-3 },
            .{ .invc = 0x1.2bef9a8b7fd2ap+0, .logc = -0x1.4462c51d20000p-3 },
            .{ .invc = 0x1.2a91c7a0c1babp+0, .logc = -0x1.3b08abc830000p-3 },
            .{ .invc = 0x1.293726014b530p+0, .logc = -0x1.31b996b490000p-3 },
            .{ .invc = 0x1.27dfa5757a1f5p+0, .logc = -0x1.2875490a44000p-3 },
            .{ .invc = 0x1.268b39b1d3bbfp+0, .logc = -0x1.1f3b9f879a000p-3 },
            .{ .invc = 0x1.2539d838ff5bdp+0, .logc = -0x1.160c8252ca000p-3 },
            .{ .invc = 0x1.23eb7aac9083bp+0, .logc = -0x1.0ce7f57f72000p-3 },
            .{ .invc = 0x1.22a012ba940b6p+0, .logc = -0x1.03cdc49fea000p-3 },
            .{ .invc = 0x1.2157996cc4132p+0, .logc = -0x1.f57bdbc4b8000p-4 },
            .{ .invc = 0x1.201201dd2fc9bp+0, .logc = -0x1.e370896404000p-4 },
            .{ .invc = 0x1.1ecf4494d480bp+0, .logc = -0x1.d17983ef94000p-4 },
            .{ .invc = 0x1.1d8f5528f6569p+0, .logc = -0x1.bf9674ed8a000p-4 },
            .{ .invc = 0x1.1c52311577e7cp+0, .logc = -0x1.adc79202f6000p-4 },
            .{ .invc = 0x1.1b17c74cb26e9p+0, .logc = -0x1.9c0c3e7288000p-4 },
            .{ .invc = 0x1.19e010c2c1ab6p+0, .logc = -0x1.8a646b372c000p-4 },
            .{ .invc = 0x1.18ab07bb670bdp+0, .logc = -0x1.78d01b3ac0000p-4 },
            .{ .invc = 0x1.1778a25efbcb6p+0, .logc = -0x1.674f145380000p-4 },
            .{ .invc = 0x1.1648d354c31dap+0, .logc = -0x1.55e0e6d878000p-4 },
            .{ .invc = 0x1.151b990275fddp+0, .logc = -0x1.4485cdea1e000p-4 },
            .{ .invc = 0x1.13f0ea432d24cp+0, .logc = -0x1.333d94d6aa000p-4 },
            .{ .invc = 0x1.12c8b7210f9dap+0, .logc = -0x1.22079f8c56000p-4 },
            .{ .invc = 0x1.11a3028ecb531p+0, .logc = -0x1.10e4698622000p-4 },
            .{ .invc = 0x1.107fbda8434afp+0, .logc = -0x1.ffa6c6ad20000p-5 },
            .{ .invc = 0x1.0f5ee0f4e6bb3p+0, .logc = -0x1.dda8d4a774000p-5 },
            .{ .invc = 0x1.0e4065d2a9fcep+0, .logc = -0x1.bbcece4850000p-5 },
            .{ .invc = 0x1.0d244632ca521p+0, .logc = -0x1.9a1894012c000p-5 },
            .{ .invc = 0x1.0c0a77ce2981ap+0, .logc = -0x1.788583302c000p-5 },
            .{ .invc = 0x1.0af2f83c636d1p+0, .logc = -0x1.5715e67d68000p-5 },
            .{ .invc = 0x1.09ddb98a01339p+0, .logc = -0x1.35c8a49658000p-5 },
            .{ .invc = 0x1.08cabaf52e7dfp+0, .logc = -0x1.149e364154000p-5 },
            .{ .invc = 0x1.07b9f2f4e28fbp+0, .logc = -0x1.e72c082eb8000p-6 },
            .{ .invc = 0x1.06ab58c358f19p+0, .logc = -0x1.a55f152528000p-6 },
            .{ .invc = 0x1.059eea5ecf92cp+0, .logc = -0x1.63d62cf818000p-6 },
            .{ .invc = 0x1.04949cdd12c90p+0, .logc = -0x1.228fb8caa0000p-6 },
            .{ .invc = 0x1.038c6c6f0ada9p+0, .logc = -0x1.c317b20f90000p-7 },
            .{ .invc = 0x1.02865137932a9p+0, .logc = -0x1.419355daa0000p-7 },
            .{ .invc = 0x1.0182427ea7348p+0, .logc = -0x1.81203c2ec0000p-8 },
            .{ .invc = 0x1.008040614b195p+0, .logc = -0x1.0040979240000p-9 },
            .{ .invc = 0x1.fe01ff726fa1ap-1, .logc = 0x1.feff384900000p-9 },
            .{ .invc = 0x1.fa11cc261ea74p-1, .logc = 0x1.7dc41353d0000p-7 },
            .{ .invc = 0x1.f6310b081992ep-1, .logc = 0x1.3cea3c4c28000p-6 },
            .{ .invc = 0x1.f25f63ceeadcdp-1, .logc = 0x1.b9fc114890000p-6 },
            .{ .invc = 0x1.ee9c8039113e7p-1, .logc = 0x1.1b0d8ce110000p-5 },
            .{ .invc = 0x1.eae8078cbb1abp-1, .logc = 0x1.58a5bd001c000p-5 },
            .{ .invc = 0x1.e741aa29d0c9bp-1, .logc = 0x1.95c8340d88000p-5 },
            .{ .invc = 0x1.e3a91830a99b5p-1, .logc = 0x1.d276aef578000p-5 },
            .{ .invc = 0x1.e01e009609a56p-1, .logc = 0x1.07598e598c000p-4 },
            .{ .invc = 0x1.dca01e577bb98p-1, .logc = 0x1.253f5e30d2000p-4 },
            .{ .invc = 0x1.d92f20b7c9103p-1, .logc = 0x1.42edd8b380000p-4 },
            .{ .invc = 0x1.d5cac66fb5ccep-1, .logc = 0x1.606598757c000p-4 },
            .{ .invc = 0x1.d272caa5ede9dp-1, .logc = 0x1.7da76356a0000p-4 },
            .{ .invc = 0x1.cf26e3e6b2ccdp-1, .logc = 0x1.9ab434e1c6000p-4 },
            .{ .invc = 0x1.cbe6da2a77902p-1, .logc = 0x1.b78c7bb0d6000p-4 },
            .{ .invc = 0x1.c8b266d37086dp-1, .logc = 0x1.d431332e72000p-4 },
            .{ .invc = 0x1.c5894bd5d5804p-1, .logc = 0x1.f0a3171de6000p-4 },
            .{ .invc = 0x1.c26b533bb9f8cp-1, .logc = 0x1.067152b914000p-3 },
            .{ .invc = 0x1.bf583eeece73fp-1, .logc = 0x1.147858292b000p-3 },
            .{ .invc = 0x1.bc4fd75db96c1p-1, .logc = 0x1.2266ecdca3000p-3 },
            .{ .invc = 0x1.b951e0c864a28p-1, .logc = 0x1.303d7a6c55000p-3 },
            .{ .invc = 0x1.b65e2c5ef3e2cp-1, .logc = 0x1.3dfc33c331000p-3 },
            .{ .invc = 0x1.b374867c9888bp-1, .logc = 0x1.4ba366b7a8000p-3 },
            .{ .invc = 0x1.b094b211d304ap-1, .logc = 0x1.5933928d1f000p-3 },
            .{ .invc = 0x1.adbe885f2ef7ep-1, .logc = 0x1.66acd2418f000p-3 },
            .{ .invc = 0x1.aaf1d31603da2p-1, .logc = 0x1.740f8ec669000p-3 },
            .{ .invc = 0x1.a82e63fd358a7p-1, .logc = 0x1.815c0f51af000p-3 },
            .{ .invc = 0x1.a5740ef09738bp-1, .logc = 0x1.8e92954f68000p-3 },
            .{ .invc = 0x1.a2c2a90ab4b27p-1, .logc = 0x1.9bb3602f84000p-3 },
            .{ .invc = 0x1.a01a01393f2d1p-1, .logc = 0x1.a8bed1c2c0000p-3 },
            .{ .invc = 0x1.9d79f24db3c1bp-1, .logc = 0x1.b5b515c01d000p-3 },
            .{ .invc = 0x1.9ae2505c7b190p-1, .logc = 0x1.c2967ccbcc000p-3 },
            .{ .invc = 0x1.9852ef297ce2fp-1, .logc = 0x1.cf635d5486000p-3 },
            .{ .invc = 0x1.95cbaeea44b75p-1, .logc = 0x1.dc1bd3446c000p-3 },
            .{ .invc = 0x1.934c69de74838p-1, .logc = 0x1.e8c01b8cfe000p-3 },
            .{ .invc = 0x1.90d4f2f6752e6p-1, .logc = 0x1.f5509c0179000p-3 },
            .{ .invc = 0x1.8e6528effd79dp-1, .logc = 0x1.00e6c121fb800p-2 },
            .{ .invc = 0x1.8bfce9fcc007cp-1, .logc = 0x1.071b80e93d000p-2 },
            .{ .invc = 0x1.899c0dabec30ep-1, .logc = 0x1.0d46b9e867000p-2 },
            .{ .invc = 0x1.87427aa2317fbp-1, .logc = 0x1.13687334bd000p-2 },
            .{ .invc = 0x1.84f00acb39a08p-1, .logc = 0x1.1980d67234800p-2 },
            .{ .invc = 0x1.82a49e8653e55p-1, .logc = 0x1.1f8ffe0cc8000p-2 },
            .{ .invc = 0x1.8060195f40260p-1, .logc = 0x1.2595fd7636800p-2 },
            .{ .invc = 0x1.7e22563e0a329p-1, .logc = 0x1.2b9300914a800p-2 },
            .{ .invc = 0x1.7beb377dcb5adp-1, .logc = 0x1.3187210436000p-2 },
            .{ .invc = 0x1.79baa679725c2p-1, .logc = 0x1.377266dec1800p-2 },
            .{ .invc = 0x1.77907f2170657p-1, .logc = 0x1.3d54ffbaf3000p-2 },
            .{ .invc = 0x1.756cadbd6130cp-1, .logc = 0x1.432eee32fe000p-2 },
        };

        const tab2 = [128]struct { chi: f64, clo: f64 }{
            .{ .chi = 0x1.61000014fb66bp-1, .clo = 0x1.e026c91425b3cp-56 },
            .{ .chi = 0x1.63000034db495p-1, .clo = 0x1.dbfea48005d41p-55 },
            .{ .chi = 0x1.650000d94d478p-1, .clo = 0x1.e7fa786d6a5b7p-55 },
            .{ .chi = 0x1.67000074e6fadp-1, .clo = 0x1.1fcea6b54254cp-57 },
            .{ .chi = 0x1.68ffffedf0faep-1, .clo = -0x1.c7e274c590efdp-56 },
            .{ .chi = 0x1.6b0000763c5bcp-1, .clo = -0x1.ac16848dcda01p-55 },
            .{ .chi = 0x1.6d0001e5cc1f6p-1, .clo = 0x1.33f1c9d499311p-55 },
            .{ .chi = 0x1.6efffeb05f63ep-1, .clo = -0x1.e80041ae22d53p-56 },
            .{ .chi = 0x1.710000e86978p-1, .clo = 0x1.bff6671097952p-56 },
            .{ .chi = 0x1.72ffffc67e912p-1, .clo = 0x1.c00e226bd8724p-55 },
            .{ .chi = 0x1.74fffdf81116ap-1, .clo = -0x1.e02916ef101d2p-57 },
            .{ .chi = 0x1.770000f679c9p-1, .clo = -0x1.7fc71cd549c74p-57 },
            .{ .chi = 0x1.78ffffa7ec835p-1, .clo = 0x1.1bec19ef50483p-55 },
            .{ .chi = 0x1.7affffe20c2e6p-1, .clo = -0x1.07e1729cc6465p-56 },
            .{ .chi = 0x1.7cfffed3fc9p-1, .clo = -0x1.08072087b8b1cp-55 },
            .{ .chi = 0x1.7efffe9261a76p-1, .clo = 0x1.dc0286d9df9aep-55 },
            .{ .chi = 0x1.81000049ca3e8p-1, .clo = 0x1.97fd251e54c33p-55 },
            .{ .chi = 0x1.8300017932c8fp-1, .clo = -0x1.afee9b630f381p-55 },
            .{ .chi = 0x1.850000633739cp-1, .clo = 0x1.9bfbf6b6535bcp-55 },
            .{ .chi = 0x1.87000204289c6p-1, .clo = -0x1.bbf65f3117b75p-55 },
            .{ .chi = 0x1.88fffebf57904p-1, .clo = -0x1.9006ea23dcb57p-55 },
            .{ .chi = 0x1.8b00022bc04dfp-1, .clo = -0x1.d00df38e04b0ap-56 },
            .{ .chi = 0x1.8cfffe50c1b8ap-1, .clo = -0x1.8007146ff9f05p-55 },
            .{ .chi = 0x1.8effffc918e43p-1, .clo = 0x1.3817bd07a7038p-55 },
            .{ .chi = 0x1.910001efa5fc7p-1, .clo = 0x1.93e9176dfb403p-55 },
            .{ .chi = 0x1.9300013467bb9p-1, .clo = 0x1.f804e4b980276p-56 },
            .{ .chi = 0x1.94fffe6ee076fp-1, .clo = -0x1.f7ef0d9ff622ep-55 },
            .{ .chi = 0x1.96fffde3c12d1p-1, .clo = -0x1.082aa962638bap-56 },
            .{ .chi = 0x1.98ffff4458a0dp-1, .clo = -0x1.7801b9164a8efp-55 },
            .{ .chi = 0x1.9afffdd982e3ep-1, .clo = -0x1.740e08a5a9337p-55 },
            .{ .chi = 0x1.9cfffed49fb66p-1, .clo = 0x1.fce08c19bep-60 },
            .{ .chi = 0x1.9f00020f19c51p-1, .clo = -0x1.a3faa27885b0ap-55 },
            .{ .chi = 0x1.a10001145b006p-1, .clo = 0x1.4ff489958da56p-56 },
            .{ .chi = 0x1.a300007bbf6fap-1, .clo = 0x1.cbeab8a2b6d18p-55 },
            .{ .chi = 0x1.a500010971d79p-1, .clo = 0x1.8fecadd78793p-55 },
            .{ .chi = 0x1.a70001df52e48p-1, .clo = -0x1.f41763dd8abdbp-55 },
            .{ .chi = 0x1.a90001c593352p-1, .clo = -0x1.ebf0284c27612p-55 },
            .{ .chi = 0x1.ab0002a4f3e4bp-1, .clo = -0x1.9fd043cff3f5fp-57 },
            .{ .chi = 0x1.acfffd7ae1ed1p-1, .clo = -0x1.23ee7129070b4p-55 },
            .{ .chi = 0x1.aefffee510478p-1, .clo = 0x1.a063ee00edea3p-57 },
            .{ .chi = 0x1.b0fffdb650d5bp-1, .clo = 0x1.a06c8381f0ab9p-58 },
            .{ .chi = 0x1.b2ffffeaaca57p-1, .clo = -0x1.9011e74233c1dp-56 },
            .{ .chi = 0x1.b4fffd995badcp-1, .clo = -0x1.9ff1068862a9fp-56 },
            .{ .chi = 0x1.b7000249e659cp-1, .clo = 0x1.aff45d0864f3ep-55 },
            .{ .chi = 0x1.b8ffff987164p-1, .clo = 0x1.cfe7796c2c3f9p-56 },
            .{ .chi = 0x1.bafffd204cb4fp-1, .clo = -0x1.3ff27eef22bc4p-57 },
            .{ .chi = 0x1.bcfffd2415c45p-1, .clo = -0x1.cffb7ee3bea21p-57 },
            .{ .chi = 0x1.beffff86309dfp-1, .clo = -0x1.14103972e0b5cp-55 },
            .{ .chi = 0x1.c0fffe1b57653p-1, .clo = 0x1.bc16494b76a19p-55 },
            .{ .chi = 0x1.c2ffff1fa57e3p-1, .clo = -0x1.4feef8d30c6edp-57 },
            .{ .chi = 0x1.c4fffdcbfe424p-1, .clo = -0x1.43f68bcec4775p-55 },
            .{ .chi = 0x1.c6fffed54b9f7p-1, .clo = 0x1.47ea3f053e0ecp-55 },
            .{ .chi = 0x1.c8fffeb998fd5p-1, .clo = 0x1.383068df992f1p-56 },
            .{ .chi = 0x1.cb0002125219ap-1, .clo = -0x1.8fd8e64180e04p-57 },
            .{ .chi = 0x1.ccfffdd94469cp-1, .clo = 0x1.e7ebe1cc7ea72p-55 },
            .{ .chi = 0x1.cefffeafdc476p-1, .clo = 0x1.ebe39ad9f88fep-55 },
            .{ .chi = 0x1.d1000169af82bp-1, .clo = 0x1.57d91a8b95a71p-56 },
            .{ .chi = 0x1.d30000d0ff71dp-1, .clo = 0x1.9c1906970c7dap-55 },
            .{ .chi = 0x1.d4fffea790fc4p-1, .clo = -0x1.80e37c558fe0cp-58 },
            .{ .chi = 0x1.d70002edc87e5p-1, .clo = -0x1.f80d64dc10f44p-56 },
            .{ .chi = 0x1.d900021dc82aap-1, .clo = -0x1.47c8f94fd5c5cp-56 },
            .{ .chi = 0x1.dafffd86b0283p-1, .clo = 0x1.c7f1dc521617ep-55 },
            .{ .chi = 0x1.dd000296c4739p-1, .clo = 0x1.8019eb2ffb153p-55 },
            .{ .chi = 0x1.defffe54490f5p-1, .clo = 0x1.e00d2c652cc89p-57 },
            .{ .chi = 0x1.e0fffcdabf694p-1, .clo = -0x1.f8340202d69d2p-56 },
            .{ .chi = 0x1.e2fffdb52c8ddp-1, .clo = 0x1.b00c1ca1b0864p-56 },
            .{ .chi = 0x1.e4ffff24216efp-1, .clo = 0x1.2ffa8b094ab51p-56 },
            .{ .chi = 0x1.e6fffe88a5e11p-1, .clo = -0x1.7f673b1efbe59p-58 },
            .{ .chi = 0x1.e9000119eff0dp-1, .clo = -0x1.4808d5e0bc801p-55 },
            .{ .chi = 0x1.eafffdfa51744p-1, .clo = 0x1.80006d54320b5p-56 },
            .{ .chi = 0x1.ed0001a127fa1p-1, .clo = -0x1.002f860565c92p-58 },
            .{ .chi = 0x1.ef00007babcc4p-1, .clo = -0x1.540445d35e611p-55 },
            .{ .chi = 0x1.f0ffff57a8d02p-1, .clo = -0x1.ffb3139ef9105p-59 },
            .{ .chi = 0x1.f30001ee58ac7p-1, .clo = 0x1.a81acf2731155p-55 },
            .{ .chi = 0x1.f4ffff5823494p-1, .clo = 0x1.a3f41d4d7c743p-55 },
            .{ .chi = 0x1.f6ffffca94c6bp-1, .clo = -0x1.202f41c987875p-57 },
            .{ .chi = 0x1.f8fffe1f9c441p-1, .clo = 0x1.77dd1f477e74bp-56 },
            .{ .chi = 0x1.fafffd2e0e37ep-1, .clo = -0x1.f01199a7ca331p-57 },
            .{ .chi = 0x1.fd0001c77e49ep-1, .clo = 0x1.181ee4bceacb1p-56 },
            .{ .chi = 0x1.feffff7e0c331p-1, .clo = -0x1.e05370170875ap-57 },
            .{ .chi = 0x1.00ffff465606ep+0, .clo = -0x1.a7ead491c0adap-55 },
            .{ .chi = 0x1.02ffff3867a58p+0, .clo = -0x1.77f69c3fcb2ep-54 },
            .{ .chi = 0x1.04ffffdfc0d17p+0, .clo = 0x1.7bffe34cb945bp-54 },
            .{ .chi = 0x1.0700003cd4d82p+0, .clo = 0x1.20083c0e456cbp-55 },
            .{ .chi = 0x1.08ffff9f2cbe8p+0, .clo = -0x1.dffdfbe37751ap-57 },
            .{ .chi = 0x1.0b000010cda65p+0, .clo = -0x1.13f7faee626ebp-54 },
            .{ .chi = 0x1.0d00001a4d338p+0, .clo = 0x1.07dfa79489ff7p-55 },
            .{ .chi = 0x1.0effffadafdfdp+0, .clo = -0x1.7040570d66bcp-56 },
            .{ .chi = 0x1.110000bbafd96p+0, .clo = 0x1.e80d4846d0b62p-55 },
            .{ .chi = 0x1.12ffffae5f45dp+0, .clo = 0x1.dbffa64fd36efp-54 },
            .{ .chi = 0x1.150000dd59ad9p+0, .clo = 0x1.a0077701250aep-54 },
            .{ .chi = 0x1.170000f21559ap+0, .clo = 0x1.dfdf9e2e3deeep-55 },
            .{ .chi = 0x1.18ffffc275426p+0, .clo = 0x1.10030dc3b7273p-54 },
            .{ .chi = 0x1.1b000123d3c59p+0, .clo = 0x1.97f7980030188p-54 },
            .{ .chi = 0x1.1cffff8299eb7p+0, .clo = -0x1.5f932ab9f8c67p-57 },
            .{ .chi = 0x1.1effff48ad4p+0, .clo = 0x1.37fbf9da75bebp-54 },
            .{ .chi = 0x1.210000c8b86a4p+0, .clo = 0x1.f806b91fd5b22p-54 },
            .{ .chi = 0x1.2300003854303p+0, .clo = 0x1.3ffc2eb9fbf33p-54 },
            .{ .chi = 0x1.24fffffbcf684p+0, .clo = 0x1.601e77e2e2e72p-56 },
            .{ .chi = 0x1.26ffff52921d9p+0, .clo = 0x1.ffcbb767f0c61p-56 },
            .{ .chi = 0x1.2900014933a3cp+0, .clo = -0x1.202ca3c02412bp-56 },
            .{ .chi = 0x1.2b00014556313p+0, .clo = -0x1.2808233f21f02p-54 },
            .{ .chi = 0x1.2cfffebfe523bp+0, .clo = -0x1.8ff7e384fdcf2p-55 },
            .{ .chi = 0x1.2f0000bb8ad96p+0, .clo = -0x1.5ff51503041c5p-55 },
            .{ .chi = 0x1.30ffffb7ae2afp+0, .clo = -0x1.10071885e289dp-55 },
            .{ .chi = 0x1.32ffffeac5f7fp+0, .clo = -0x1.1ff5d3fb7b715p-54 },
            .{ .chi = 0x1.350000ca66756p+0, .clo = 0x1.57f82228b82bdp-54 },
            .{ .chi = 0x1.3700011fbf721p+0, .clo = 0x1.000bac40dd5ccp-55 },
            .{ .chi = 0x1.38ffff9592fb9p+0, .clo = -0x1.43f9d2db2a751p-54 },
            .{ .chi = 0x1.3b00004ddd242p+0, .clo = 0x1.57f6b707638e1p-55 },
            .{ .chi = 0x1.3cffff5b2c957p+0, .clo = 0x1.a023a10bf1231p-56 },
            .{ .chi = 0x1.3efffeab0b418p+0, .clo = 0x1.87f6d66b152bp-54 },
            .{ .chi = 0x1.410001532aff4p+0, .clo = 0x1.7f8375f198524p-57 },
            .{ .chi = 0x1.4300017478b29p+0, .clo = 0x1.301e672dc5143p-55 },
            .{ .chi = 0x1.44fffe795b463p+0, .clo = 0x1.9ff69b8b2895ap-55 },
            .{ .chi = 0x1.46fffe80475ep+0, .clo = -0x1.5c0b19bc2f254p-54 },
            .{ .chi = 0x1.48fffef6fc1e7p+0, .clo = 0x1.b4009f23a2a72p-54 },
            .{ .chi = 0x1.4afffe5bea704p+0, .clo = -0x1.4ffb7bf0d7d45p-54 },
            .{ .chi = 0x1.4d000171027dep+0, .clo = -0x1.9c06471dc6a3dp-54 },
            .{ .chi = 0x1.4f0000ff03ee2p+0, .clo = 0x1.77f890b85531cp-54 },
            .{ .chi = 0x1.5100012dc4bd1p+0, .clo = 0x1.004657166a436p-57 },
            .{ .chi = 0x1.530001605277ap+0, .clo = -0x1.6bfcece233209p-54 },
            .{ .chi = 0x1.54fffecdb704cp+0, .clo = -0x1.902720505a1d7p-55 },
            .{ .chi = 0x1.56fffef5f54a9p+0, .clo = 0x1.bbfe60ec96412p-54 },
            .{ .chi = 0x1.5900017e61012p+0, .clo = 0x1.87ec581afef9p-55 },
            .{ .chi = 0x1.5b00003c93e92p+0, .clo = -0x1.f41080abf0ccp-54 },
            .{ .chi = 0x1.5d0001d4919bcp+0, .clo = -0x1.8812afb254729p-54 },
            .{ .chi = 0x1.5efffe7b87a89p+0, .clo = -0x1.47eb780ed6904p-54 },
        };

        var ix: i64 = @bitCast(x);

        const LO: i64 = @bitCast(@as(f64, 1.0 - 0x1p-4));
        const HI: i64 = @bitCast(@as(f64, 1.0 + 0x1.09p-4));
        if (LO <= ix and ix < HI) {
            @branchHint(.unlikely);
            if (ix == @as(i64, @bitCast(@as(f64, 1)))) {
                @branchHint(.unlikely);
                return 0;
            }

            const r = x - 1;
            const r2 = r * r;
            const r3 = r * r2;

            const y = r3 * (poly1[1] + r * poly1[2] + r2 * poly1[3] +
                r3 * (poly1[4] + r * poly1[5] + r2 * poly1[6] +
                    r3 * (poly1[7] + r * poly1[8] + r2 * poly1[9] + r3 * poly1[10])));

            var w = r * 0x1p27;
            const rhi = r + w - w;
            const rlo = r - rhi;
            w = rhi * rhi * poly1[0];
            const hi = r + w;
            const lo = r - hi + w + poly1[0] * rlo * (rhi + r);
            return y + lo + hi;
        }
        const top = @as(u64, @bitCast(ix)) >> 48;
        if (top < 0x0010 or 0x7ff0 <= top) {
            @branchHint(.unlikely);

            if (ix << 1 == 0)
                return if (compiler_rt.want_float_exceptions) -1 / (x * x) else -std.math.inf(f64);

            if (ix == @as(i64, @bitCast(std.math.inf(f64))))
                return x;

            if (top & 0x8000 != 0 or top & 0x7ff0 == 0x7ff0)
                return if (compiler_rt.want_float_exceptions) (x - x) / 0.0 else math.nan(f64);

            ix = @as(i64, @bitCast(x * 0x1p52)) - (52 << 52);
        }

        const tmp: packed struct(i64) { unused: u45, i: u7, k: i12 } = @bitCast(ix - 0x3fe6000000000000);
        const i = tmp.i;
        const k = tmp.k;
        const iz = ix - (@as(i64, tmp.k) << 52);
        const invc = tab[i].invc;
        const logc = tab[i].logc;
        const z: f64 = @bitCast(iz);

        // maybe use fma as musl does
        const r = (z - tab2[i].chi - tab2[i].clo) * invc;

        const kd: f64 = k;
        const w = kd * 0x1.62e42fefa3800p-1 + logc;
        const hi = w + r;
        const lo = w - hi + r + kd * 0x1.ef35793c76730p-45;

        const r2 = r * r;

        const y = lo + r2 * poly[0] + r * r2 * (poly[1] + r * poly[2] + r2 * (poly[3] + r * poly[4])) + hi;
        return @bitCast(y);
    }
};

/// From `lib/compiler_rt/trig.zig`.
pub const trig_kernel = struct {
    pub fn cos(x: f64, y: f64) f64 {
        const C1 = 4.16666666666666019037e-02; // 0x3FA55555, 0x5555554C
        const C2 = -1.38888888888741095749e-03; // 0xBF56C16C, 0x16C15177
        const C3 = 2.48015872894767294178e-05; // 0x3EFA01A0, 0x19CB1590
        const C4 = -2.75573143513906633035e-07; // 0xBE927E4F, 0x809C52AD
        const C5 = 2.08757232129817482790e-09; // 0x3E21EE9E, 0xBDB4B1C4
        const C6 = -1.13596475577881948265e-11; // 0xBDA8FAE9, 0xBE8838D4

        const z = x * x;
        const zs = z * z;
        const r = z * (C1 + z * (C2 + z * C3)) + zs * zs * (C4 + z * (C5 + z * C6));
        const hz = 0.5 * z;
        const w = 1.0 - hz;
        return w + (((1.0 - w) - hz) + (z * r - x * y));
    }

    pub fn sin(x: f64, y: f64, iy: i32) f64 {
        const S1 = -1.66666666666666324348e-01; // 0xBFC55555, 0x55555549
        const S2 = 8.33333333332248946124e-03; // 0x3F811111, 0x1110F8A6
        const S3 = -1.98412698298579493134e-04; // 0xBF2A01A0, 0x19C161D5
        const S4 = 2.75573137070700676789e-06; // 0x3EC71DE3, 0x57B1FE7D
        const S5 = -2.50507602534068634195e-08; // 0xBE5AE5E6, 0x8A2B9CEB
        const S6 = 1.58969099521155010221e-10; // 0x3DE5D93A, 0x5ACFD57C

        const z = x * x;
        const w = z * z;
        const r = S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6);
        const v = z * x;
        if (iy == 0) {
            return x + v * (S1 + z * r);
        } else {
            return x - ((z * (0.5 * y - v * r) - y) - v * S1);
        }
    }

    pub fn tan(x_: f64, y_: f64, odd: bool) f64 {
        var x = x_;
        var y = y_;

        const T = [_]f64{
            3.33333333333334091986e-01, // 3FD55555, 55555563
            1.33333333333201242699e-01, // 3FC11111, 1110FE7A
            5.39682539762260521377e-02, // 3FABA1BA, 1BB341FE
            2.18694882948595424599e-02, // 3F9664F4, 8406D637
            8.86323982359930005737e-03, // 3F8226E3, E96E8493
            3.59207910759131235356e-03, // 3F6D6D22, C9560328
            1.45620945432529025516e-03, // 3F57DBC8, FEE08315
            5.88041240820264096874e-04, // 3F4344D8, F2F26501
            2.46463134818469906812e-04, // 3F3026F7, 1A8D1068
            7.81794442939557092300e-05, // 3F147E88, A03792A6
            7.14072491382608190305e-05, // 3F12B80F, 32F0A7E9
            -1.85586374855275456654e-05, // BEF375CB, DB605373
            2.59073051863633712884e-05, // 3EFB2A70, 74BF7AD4
        };
        const pio4 = 7.85398163397448278999e-01; // 3FE921FB, 54442D18
        const pio4lo = 3.06161699786838301793e-17; // 3C81A626, 33145C07

        var z: f64 = undefined;
        var r: f64 = undefined;
        var v: f64 = undefined;
        var w: f64 = undefined;
        var s: f64 = undefined;
        var a: f64 = undefined;
        var w0: f64 = undefined;
        var a0: f64 = undefined;
        var hx: u32 = undefined;
        var sign: bool = undefined;

        hx = @intCast(@as(u64, @bitCast(x)) >> 32);
        const big = (hx & 0x7fffffff) >= 0x3FE59428; // |x| >= 0.6744
        if (big) {
            sign = hx >> 31 != 0;
            if (sign) {
                x = -x;
                y = -y;
            }
            x = (pio4 - x) + (pio4lo - y);
            y = 0.0;
        }
        z = x * x;
        w = z * z;

        // Break x^5*(T[1]+x^2*T[2]+...) into
        // x^5(T[1]+x^4*T[3]+...+x^20*T[11]) +
        // x^5(x^2*(T[2]+x^4*T[4]+...+x^22*[T12]))
        r = T[1] + w * (T[3] + w * (T[5] + w * (T[7] + w * (T[9] + w * T[11]))));
        v = z * (T[2] + w * (T[4] + w * (T[6] + w * (T[8] + w * (T[10] + w * T[12])))));
        s = z * x;
        r = y + z * (s * (r + v) + y) + s * T[0];
        w = x + r;
        if (big) {
            s = @floatFromInt(1 - 2 * @as(i3, @intFromBool(odd)));
            v = s - 2.0 * (x + (r - w * w / (w + s)));
            return if (sign) -v else v;
        }
        if (!odd) {
            return w;
        }
        // -1.0/(x+r) has up to 2ulp error, so compute it accurately
        w0 = w;
        w0 = @bitCast(@as(u64, @bitCast(w0)) & 0xffffffff00000000);
        v = r - (w0 - x); // w0+v = r+x
        a = -1.0 / w;
        a0 = a;
        a0 = @bitCast(@as(u64, @bitCast(a0)) & 0xffffffff00000000);
        return a0 + a * (1.0 + a0 * w0 + a0 * v);
    }
};

/// From `lib/compiler_rt/rem_pio2_large.zig`.
pub const rem_pio2_large_kernel = struct {
    const init_jk = [_]i32{ 3, 4, 4, 6 }; // initial value for jk

    const ipio2 = [_]i32{
        0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62,
        0x95993C, 0x439041, 0xFE5163, 0xABDEBB, 0xC561B7, 0x246E3A,
        0x424DD2, 0xE00649, 0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129,
        0xA73EE8, 0x8235F5, 0x2EBB44, 0x84E99C, 0x7026B4, 0x5F7E41,
        0x3991D6, 0x398353, 0x39F49C, 0x845F8B, 0xBDF928, 0x3B1FF8,
        0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D, 0x367ECF,
        0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5,
        0xF17B3D, 0x0739F7, 0x8A5292, 0xEA6BFB, 0x5FB11F, 0x8D5D08,
        0x560330, 0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3,
        0x91615E, 0xE61B08, 0x659985, 0x5F14A0, 0x68408D, 0xFFD880,
        0x4D7327, 0x310606, 0x1556CA, 0x73A8C9, 0x60E27B, 0xC08C6B,

        0x47C419, 0xC367CD, 0xDCE809, 0x2A8359, 0xC4768B, 0x961CA6,
        0xDDAF44, 0xD15719, 0x053EA5, 0xFF0705, 0x3F7E33, 0xE832C2,
        0xDE4F98, 0x327DBB, 0xC33D26, 0xEF6B1E, 0x5EF89F, 0x3A1F35,
        0xCAF27F, 0x1D87F1, 0x21907C, 0x7C246A, 0xFA6ED5, 0x772D30,
        0x433B15, 0xC614B5, 0x9D19C3, 0xC2C4AD, 0x414D2C, 0x5D000C,
        0x467D86, 0x2D71E3, 0x9AC69B, 0x006233, 0x7CD2B4, 0x97A7B4,
        0xD55537, 0xF63ED7, 0x1810A3, 0xFC764D, 0x2A9D64, 0xABD770,
        0xF87C63, 0x57B07A, 0xE71517, 0x5649C0, 0xD9D63B, 0x3884A7,
        0xCB2324, 0x778AD6, 0x23545A, 0xB91F00, 0x1B0AF1, 0xDFCE19,
        0xFF319F, 0x6A1E66, 0x615799, 0x47FBAC, 0xD87F7E, 0xB76522,
        0x89E832, 0x60BFE6, 0xCDC4EF, 0x09366C, 0xD43F5D, 0xD7DE16,
        0xDE3B58, 0x929BDE, 0x2822D2, 0xE88628, 0x4D58E2, 0x32CAC6,
        0x16E308, 0xCB7DE0, 0x50C017, 0xA71DF3, 0x5BE018, 0x34132E,
        0x621283, 0x014883, 0x5B8EF5, 0x7FB0AD, 0xF2E91E, 0x434A48,
        0xD36710, 0xD8DDAA, 0x425FAE, 0xCE616A, 0xA4280A, 0xB499D3,
        0xF2A606, 0x7F775C, 0x83C2A3, 0x883C61, 0x78738A, 0x5A8CAF,
        0xBDD76F, 0x63A62D, 0xCBBFF4, 0xEF818D, 0x67C126, 0x45CA55,
        0x36D9CA, 0xD2A828, 0x8D61C2, 0x77C912, 0x142604, 0x9B4612,
        0xC459C4, 0x44C5C8, 0x91B24D, 0xF31700, 0xAD43D4, 0xE54929,
        0x10D5FD, 0xFCBE00, 0xCC941E, 0xEECE70, 0xF53E13, 0x80F1EC,
        0xC3E7B3, 0x28F8C7, 0x940593, 0x3E71C1, 0xB3092E, 0xF3450B,
        0x9C1288, 0x7B20AB, 0x9FB52E, 0xC29247, 0x2F327B, 0x6D550C,
        0x90A772, 0x1FE76B, 0x96CB31, 0x4A1679, 0xE27941, 0x89DFF4,
        0x9794E8, 0x84E6E2, 0x973199, 0x6BED88, 0x365F5F, 0x0EFDBB,
        0xB49A48, 0x6CA467, 0x427271, 0x325D8D, 0xB8159F, 0x09E5BC,
        0x25318D, 0x3974F7, 0x1C0530, 0x010C0D, 0x68084B, 0x58EE2C,
        0x90AA47, 0x02E774, 0x24D6BD, 0xA67DF7, 0x72486E, 0xEF169F,
        0xA6948E, 0xF691B4, 0x5153D1, 0xF20ACF, 0x339820, 0x7E4BF5,
        0x6863B2, 0x5F3EDD, 0x035D40, 0x7F8985, 0x295255, 0xC06437,
        0x10D86D, 0x324832, 0x754C5B, 0xD4714E, 0x6E5445, 0xC1090B,
        0x69F52A, 0xD56614, 0x9D0727, 0x50045D, 0xDB3BB4, 0xC576EA,
        0x17F987, 0x7D6B49, 0xBA271D, 0x296996, 0xACCCC6, 0x5414AD,
        0x6AE290, 0x89D988, 0x50722C, 0xBEA404, 0x940777, 0x7030F3,
        0x27FC00, 0xA871EA, 0x49C266, 0x3DE064, 0x83DD97, 0x973FA3,
        0xFD9443, 0x8C860D, 0xDE4131, 0x9D3992, 0x8C70DD, 0xE7B717,
        0x3BDF08, 0x2B3715, 0xA0805C, 0x93805A, 0x921110, 0xD8E80F,
        0xAF806C, 0x4BFFDB, 0x0F9038, 0x761859, 0x15A562, 0xBBCB61,
        0xB989C7, 0xBD4010, 0x04F2D2, 0x277549, 0xF6B6EB, 0xBB22DB,
        0xAA140A, 0x2F2689, 0x768364, 0x333B09, 0x1A940E, 0xAA3A51,
        0xC2A31D, 0xAEEDAF, 0x12265C, 0x4DC26D, 0x9C7A2D, 0x9756C0,
        0x833F03, 0xF6F009, 0x8C402B, 0x99316D, 0x07B439, 0x15200C,
        0x5BC3D8, 0xC492F5, 0x4BADC6, 0xA5CA4E, 0xCD37A7, 0x36A9E6,
        0x9492AB, 0x6842DD, 0xDE6319, 0xEF8C76, 0x528B68, 0x37DBFC,
        0xABA1AE, 0x3115DF, 0xA1AE00, 0xDAFB0C, 0x664D64, 0xB705ED,
        0x306529, 0xBF5657, 0x3AFF47, 0xB9F96A, 0xF3BE75, 0xDF9328,
        0x3080AB, 0xF68C66, 0x15CB04, 0x0622FA, 0x1DE4D9, 0xA4B33D,
        0x8F1B57, 0x09CD36, 0xE9424E, 0xA4BE13, 0xB52333, 0x1AAAF0,
        0xA8654F, 0xA5C1D2, 0x0F3F0B, 0xCD785B, 0x76F923, 0x048B7B,
        0x721789, 0x53A6C6, 0xE26E6F, 0x00EBEF, 0x584A9B, 0xB7DAC4,
        0xBA66AA, 0xCFCF76, 0x1D02D1, 0x2DF1B1, 0xC1998C, 0x77ADC3,
        0xDA4886, 0xA05DF7, 0xF480C6, 0x2FF0AC, 0x9AECDD, 0xBC5C3F,
        0x6DDED0, 0x1FC790, 0xB6DB2A, 0x3A25A3, 0x9AAF00, 0x9353AD,
        0x0457B6, 0xB42D29, 0x7E804B, 0xA707DA, 0x0EAA76, 0xA1597B,
        0x2A1216, 0x2DB7DC, 0xFDE5FA, 0xFEDB89, 0xFDBE89, 0x6C76E4,
        0xFCA906, 0x70803E, 0x156E85, 0xFF87FD, 0x073E28, 0x336761,
        0x86182A, 0xEABD4D, 0xAFE7B3, 0x6E6D8F, 0x396795, 0x5BBF31,
        0x48D784, 0x16DF30, 0x432DC7, 0x356125, 0xCE70C9, 0xB8CB30,
        0xFD6CBF, 0xA200A4, 0xE46C05, 0xA0DD5A, 0x476F21, 0xD21262,
        0x845CB9, 0x496170, 0xE0566B, 0x015299, 0x375550, 0xB7D51E,
        0xC4F133, 0x5F6E13, 0xE4305D, 0xA92E85, 0xC3B21D, 0x3632A1,
        0xA4B708, 0xD4B1EA, 0x21F716, 0xE4698F, 0x77FF27, 0x80030C,
        0x2D408D, 0xA0CD4F, 0x99A520, 0xD3A2B3, 0x0A5D2F, 0x42F9B4,
        0xCBDA11, 0xD0BE7D, 0xC1DB9B, 0xBD17AB, 0x81A2CA, 0x5C6A08,
        0x17552E, 0x550027, 0xF0147F, 0x8607E1, 0x640B14, 0x8D4196,
        0xDEBE87, 0x2AFDDA, 0xB6256B, 0x34897B, 0xFEF305, 0x9EBFB9,
        0x4F6A68, 0xA82A4A, 0x5AC44F, 0xBCF82D, 0x985AD7, 0x95C7F4,
        0x8D4D0D, 0xA63A20, 0x5F57A4, 0xB13F14, 0x953880, 0x0120CC,
        0x86DD71, 0xB6DEC9, 0xF560BF, 0x11654D, 0x6B0701, 0xACB08C,
        0xD0C0B2, 0x485551, 0x0EFB1E, 0xC37295, 0x3B06A3, 0x3540C0,
        0x7BDC06, 0xCC45E0, 0xFA294E, 0xC8CAD6, 0x41F3E8, 0xDE647C,
        0xD8649B, 0x31BED9, 0xC397A4, 0xD45877, 0xC5E369, 0x13DAF0,
        0x3C3ABA, 0x461846, 0x5F7555, 0xF5BDD2, 0xC6926E, 0x5D2EAC,
        0xED440E, 0x423E1C, 0x87C461, 0xE9FD29, 0xF3D6E7, 0xCA7C22,
        0x35916F, 0xC5E008, 0x8DD7FF, 0xE26A6E, 0xC6FDB0, 0xC10893,
        0x745D7C, 0xB2AD6B, 0x9D6ECD, 0x7B723E, 0x6A11C6, 0xA9CFF7,
        0xDF7329, 0xBAC9B5, 0x5100B7, 0x0DB2E2, 0x24BA74, 0x607DE5,
        0x8AD874, 0x2C150D, 0x0C1881, 0x94667E, 0x162901, 0x767A9F,
        0xBEFDFD, 0xEF4556, 0x367ED9, 0x13D9EC, 0xB9BA8B, 0xFC97C4,
        0x27A831, 0xC36EF1, 0x36C594, 0x56A8D8, 0xB5A8B4, 0x0ECCCF,
        0x2D8912, 0x34576F, 0x89562C, 0xE3CE99, 0xB920D6, 0xAA5E6B,
        0x9C2A3E, 0xCC5F11, 0x4A0BFD, 0xFBF4E1, 0x6D3B8E, 0x2C86E2,
        0x84D4E9, 0xA9B4FC, 0xD1EEEF, 0xC9352E, 0x61392F, 0x442138,
        0xC8D91B, 0x0AFC81, 0x6A4AFB, 0xD81C2F, 0x84B453, 0x8C994E,
        0xCC2254, 0xDC552A, 0xD6C6C0, 0x96190B, 0xB8701A, 0x649569,
        0x605A26, 0xEE523F, 0x0F117F, 0x11B5F4, 0xF5CBFC, 0x2DBC34,
        0xEEBC34, 0xCC5DE8, 0x605EDD, 0x9B8E67, 0xEF3392, 0xB817C9,
        0x9B5861, 0xBC57E1, 0xC68351, 0x103ED8, 0x4871DD, 0xDD1C2D,
        0xA118AF, 0x462C21, 0xD7F359, 0x987AD9, 0xC0549E, 0xFA864F,
        0xFC0656, 0xAE79E5, 0x362289, 0x22AD38, 0xDC9367, 0xAAE855,
        0x382682, 0x9BE7CA, 0xA40D51, 0xB13399, 0x0ED7A9, 0x480569,
        0xF0B265, 0xA7887F, 0x974C88, 0x36D1F9, 0xB39221, 0x4A827B,
        0x21CF98, 0xDC9F40, 0x5547DC, 0x3A74E1, 0x42EB67, 0xDF9DFE,
        0x5FD45E, 0xA4677B, 0x7AACBA, 0xA2F655, 0x23882B, 0x55BA41,
        0x086E59, 0x862A21, 0x834739, 0xE6E389, 0xD49EE5, 0x40FB49,
        0xE956FF, 0xCA0F1C, 0x8A59C5, 0x2BFA94, 0xC5C1D3, 0xCFC50F,
        0xAE5ADB, 0x86C547, 0x624385, 0x3B8621, 0x94792C, 0x876110,
        0x7B4C2A, 0x1A2C80, 0x12BF43, 0x902688, 0x893C78, 0xE4C4A8,
        0x7BDBE5, 0xC23AC4, 0xEAF426, 0x8A67F7, 0xBF920D, 0x2BA365,
        0xB1933D, 0x0B7CBD, 0xDC51A4, 0x63DD27, 0xDDE169, 0x19949A,
        0x9529A8, 0x28CE68, 0xB4ED09, 0x209F44, 0xCA984E, 0x638270,
        0x237C7E, 0x32B90F, 0x8EF5A7, 0xE75614, 0x08F121, 0x2A9DB5,
        0x4D7E6F, 0x5119A5, 0xABF9B5, 0xD6DF82, 0x61DD96, 0x023616,
        0x9F3AC4, 0xA1A283, 0x6DED72, 0x7A8D39, 0xA9B882, 0x5C326B,
        0x5B2746, 0xED3400, 0x7700D2, 0x55F4FC, 0x4D5901, 0x8071E0,
    };

    const PIo2 = [_]f64{
        1.57079625129699707031e+00, // 0x3FF921FB, 0x40000000
        7.54978941586159635335e-08, // 0x3E74442D, 0x00000000
        5.39030252995776476554e-15, // 0x3CF84698, 0x80000000
        3.28200341580791294123e-22, // 0x3B78CC51, 0x60000000
        1.27065575308067607349e-29, // 0x39F01B83, 0x80000000
        1.22933308981111328932e-36, // 0x387A2520, 0x40000000
        2.73370053816464559624e-44, // 0x36E38222, 0x80000000
        2.16741683877804819444e-51, // 0x3569F31D, 0x00000000
    };

    pub fn rem_pio2_large(x: []const f64, y: []f64, e0: i32, nx: i32, prec: usize) i32 {
        var jz: i32 = undefined;
        var jx: i32 = undefined;
        var jv: i32 = undefined;
        var jp: i32 = undefined;
        var jk: i32 = undefined;
        var carry: i32 = undefined;
        var n: i32 = undefined;
        var iq: [20]i32 = undefined;
        var i: i32 = undefined;
        var j: i32 = undefined;
        var k: i32 = undefined;
        var m: i32 = undefined;
        var q0: i32 = undefined;
        var ih: i32 = undefined;

        var z: f64 = undefined;
        var fw: f64 = undefined;
        var f: [20]f64 = undefined;
        var fq: [20]f64 = undefined;
        var q: [20]f64 = undefined;

        // initialize jk
        jk = init_jk[prec];
        jp = jk;

        // determine jx,jv,q0, note that 3>q0
        jx = nx - 1;
        jv = @divFloor(e0 - 3, 24);
        if (jv < 0) jv = 0;
        q0 = e0 - 24 * (jv + 1);

        // set up f[0] to f[jx+jk] where f[jx+jk] = ipio2[jv+jk]
        j = jv - jx;
        m = jx + jk;
        i = 0;
        while (i <= m) : ({
            i += 1;
            j += 1;
        }) {
            f[@intCast(i)] = if (j < 0) 0.0 else @floatFromInt(ipio2[@intCast(j)]);
        }

        // compute q[0],q[1],...q[jk]
        i = 0;
        while (i <= jk) : (i += 1) {
            j = 0;
            fw = 0;
            while (j <= jx) : (j += 1) {
                fw += x[@intCast(j)] * f[@intCast(jx + i - j)];
            }
            q[@intCast(i)] = fw;
        }

        jz = jk;

        // This is to handle a non-trivial goto translation from C.
        // An unconditional return statement is found at the end of this loop.
        recompute: while (true) {
            // distill q[] into iq[] reversingly
            i = 0;
            j = jz;
            z = q[@intCast(jz)];
            while (j > 0) : ({
                i += 1;
                j -= 1;
            }) {
                fw = @floatFromInt(@as(i32, @intFromFloat(0x1p-24 * z)));
                iq[@intCast(i)] = @intFromFloat(z - 0x1p24 * fw);
                z = q[@intCast(j - 1)] + fw;
            }

            // compute n
            z = math.scalbn(z, q0); // actual value of z
            z -= 8.0 * @floor(z * 0.125); // trim off integer >= 8
            n = @intFromFloat(z);
            z -= @floatFromInt(n);
            ih = 0;
            if (q0 > 0) { // need iq[jz-1] to determine n
                i = iq[@intCast(jz - 1)] >> @intCast(24 - q0);
                n += i;
                iq[@intCast(jz - 1)] -= i << @intCast(24 - q0);
                ih = iq[@intCast(jz - 1)] >> @intCast(23 - q0);
            } else if (q0 == 0) {
                ih = iq[@intCast(jz - 1)] >> 23;
            } else if (z >= 0.5) {
                ih = 2;
            }

            if (ih > 0) { // q > 0.5
                n += 1;
                carry = 0;
                i = 0;
                while (i < jz) : (i += 1) { // compute 1-q
                    j = iq[@intCast(i)];
                    if (carry == 0) {
                        if (j != 0) {
                            carry = 1;
                            iq[@intCast(i)] = 0x1000000 - j;
                        }
                    } else {
                        iq[@intCast(i)] = 0xffffff - j;
                    }
                }
                if (q0 > 0) { // rare case: chance is 1 in 12
                    @branchHint(.unlikely);
                    switch (q0) {
                        1 => iq[@intCast(jz - 1)] &= 0x7fffff,
                        2 => iq[@intCast(jz - 1)] &= 0x3fffff,
                        else => unreachable,
                    }
                }
                if (ih == 2) {
                    z = 1.0 - z;
                    if (carry != 0) {
                        z -= math.scalbn(@as(f64, 1.0), q0);
                    }
                }
            }

            // check if recomputation is needed
            if (z == 0.0) {
                j = 0;
                i = jz - 1;
                while (i >= jk) : (i -= 1) {
                    j |= iq[@intCast(i)];
                }

                if (j == 0) { // need recomputation
                    k = 1;
                    while (iq[@intCast(jk - k)] == 0) : (k += 1) {
                        // k = no. of terms needed
                    }

                    i = jz + 1;
                    while (i <= jz + k) : (i += 1) { // add q[jz+1] to q[jz+k]
                        f[@intCast(jx + i)] = @floatFromInt(ipio2[@intCast(jv + i)]);
                        j = 0;
                        fw = 0;
                        while (j <= jx) : (j += 1) {
                            fw += x[@intCast(j)] * f[@intCast(jx + i - j)];
                        }
                        q[@intCast(i)] = fw;
                    }
                    jz += k;
                    continue :recompute; // mimic goto recompute
                }
            }

            // chop off zero terms
            if (z == 0.0) {
                jz -= 1;
                q0 -= 24;
                while (iq[@intCast(jz)] == 0) {
                    jz -= 1;
                    q0 -= 24;
                }
            } else { // break z into 24-bit if necessary
                z = math.scalbn(z, -q0);
                if (z >= 0x1p24) {
                    fw = @floatFromInt(@as(i32, @intFromFloat(0x1p-24 * z)));
                    iq[@intCast(jz)] = @intFromFloat(z - 0x1p24 * fw);
                    jz += 1;
                    q0 += 24;
                    iq[@intCast(jz)] = @intFromFloat(fw);
                } else {
                    iq[@intCast(jz)] = @intFromFloat(z);
                }
            }

            // convert integer "bit" chunk to floating-point value
            fw = math.scalbn(@as(f64, 1.0), q0);
            i = jz;
            while (i >= 0) : (i -= 1) {
                q[@intCast(i)] = fw * @as(f64, @floatFromInt(iq[@intCast(i)]));
                fw *= 0x1p-24;
            }

            // compute PIo2[0,...,jp]*q[jz,...,0]
            i = jz;
            while (i >= 0) : (i -= 1) {
                fw = 0;
                k = 0;
                while (k <= jp and k <= jz - i) : (k += 1) {
                    fw += PIo2[@intCast(k)] * q[@intCast(i + k)];
                }
                fq[@intCast(jz - i)] = fw;
            }

            // compress fq[] into y[]
            switch (prec) {
                0 => {
                    fw = 0.0;
                    i = jz;
                    while (i >= 0) : (i -= 1) {
                        fw += fq[@intCast(i)];
                    }
                    y[0] = if (ih == 0) fw else -fw;
                },

                1, 2 => {
                    fw = 0.0;
                    i = jz;
                    while (i >= 0) : (i -= 1) {
                        fw += fq[@intCast(i)];
                    }
                    // TODO: drop excess precision here once double_t is used
                    fw = fw;
                    y[0] = if (ih == 0) fw else -fw;
                    fw = fq[0] - fw;
                    i = 1;
                    while (i <= jz) : (i += 1) {
                        fw += fq[@intCast(i)];
                    }
                    y[1] = if (ih == 0) fw else -fw;
                },
                3 => { // painful
                    i = jz;
                    while (i > 0) : (i -= 1) {
                        fw = fq[@intCast(i - 1)] + fq[@intCast(i)];
                        fq[@intCast(i)] += fq[@intCast(i - 1)] - fw;
                        fq[@intCast(i - 1)] = fw;
                    }
                    i = jz;
                    while (i > 1) : (i -= 1) {
                        fw = fq[@intCast(i - 1)] + fq[@intCast(i)];
                        fq[@intCast(i)] += fq[@intCast(i - 1)] - fw;
                        fq[@intCast(i - 1)] = fw;
                    }
                    fw = 0;
                    i = jz;
                    while (i >= 2) : (i -= 1) {
                        fw += fq[@intCast(i)];
                    }
                    if (ih == 0) {
                        y[0] = fq[0];
                        y[1] = fq[1];
                        y[2] = fw;
                    } else {
                        y[0] = -fq[0];
                        y[1] = -fq[1];
                        y[2] = -fw;
                    }
                },
                else => unreachable,
            }

            return n & 7;
        }
    }
};

/// From `lib/compiler_rt/rem_pio2.zig`.
pub const rem_pio2_kernel = struct {
    const toint = 1.5 / math.floatEps(f64);

    const pio4 = 0x1.921fb54442d18p-1;

    const invpio2 = 6.36619772367581382433e-01; // 0x3FE45F30, 0x6DC9C883

    const pio2_1 = 1.57079632673412561417e+00; // 0x3FF921FB, 0x54400000

    const pio2_1t = 6.07710050650619224932e-11; // 0x3DD0B461, 0x1A626331

    const pio2_2 = 6.07710050630396597660e-11; // 0x3DD0B461, 0x1A600000

    const pio2_2t = 2.02226624879595063154e-21; // 0x3BA3198A, 0x2E037073

    const pio2_3 = 2.02226624871116645580e-21; // 0x3BA3198A, 0x2E000000

    const pio2_3t = 8.47842766036889956997e-32; // 0x397B839A, 0x252049C1

    pub fn medium(ix: u32, x: f64, y: *[2]f64) i32 {
        var w: f64 = undefined;
        var t: f64 = undefined;
        var r: f64 = undefined;
        var @"fn": f64 = undefined;
        var n: i32 = undefined;
        var ex: i32 = undefined;
        var ey: i32 = undefined;
        var ui: u64 = undefined;

        // rint(x/(pi/2))
        @"fn" = x * invpio2 + toint - toint;
        n = @intFromFloat(@"fn");
        r = x - @"fn" * pio2_1;
        w = @"fn" * pio2_1t; // 1st round, good to 85 bits
        // Matters with directed rounding.
        if (r - w < -pio4) {
            n -= 1;
            @"fn" -= 1;
            r = x - @"fn" * pio2_1;
            w = @"fn" * pio2_1t;
        } else if (r - w > pio4) {
            n += 1;
            @"fn" += 1;
            r = x - @"fn" * pio2_1;
            w = @"fn" * pio2_1t;
        }
        y[0] = r - w;
        ui = @bitCast(y[0]);
        ey = @intCast((ui >> 52) & 0x7ff);
        ex = @intCast(ix >> 20);
        if (ex - ey > 16) { // 2nd round, good to 118 bits
            t = r;
            w = @"fn" * pio2_2;
            r = t - w;
            w = @"fn" * pio2_2t - ((t - r) - w);
            y[0] = r - w;
            ui = @bitCast(y[0]);
            ey = @intCast((ui >> 52) & 0x7ff);
            if (ex - ey > 49) { // 3rd round, good to 151 bits, covers all cases
                t = r;
                w = @"fn" * pio2_3;
                r = t - w;
                w = @"fn" * pio2_3t - ((t - r) - w);
                y[0] = r - w;
            }
        }
        y[1] = (r - y[0]) - w;
        return n;
    }

    pub fn rem_pio2(x: f64, y: *[2]f64) i32 {
        var z: f64 = undefined;
        var tx: [3]f64 = undefined;
        var ty: [2]f64 = undefined;
        var n: i32 = undefined;
        var ix: u32 = undefined;
        var sign: bool = undefined;
        var i: i32 = undefined;
        var ui: u64 = undefined;

        ui = @bitCast(x);
        sign = ui >> 63 != 0;
        ix = @truncate((ui >> 32) & 0x7fffffff);
        if (ix <= 0x400f6a7a) { // |x| ~<= 5pi/4
            if ((ix & 0xfffff) == 0x921fb) { // |x| ~= pi/2 or 2pi/2
                return medium(ix, x, y);
            }
            if (ix <= 0x4002d97c) { // |x| ~<= 3pi/4
                if (!sign) {
                    z = x - pio2_1; // one round good to 85 bits
                    y[0] = z - pio2_1t;
                    y[1] = (z - y[0]) - pio2_1t;
                    return 1;
                } else {
                    z = x + pio2_1;
                    y[0] = z + pio2_1t;
                    y[1] = (z - y[0]) + pio2_1t;
                    return -1;
                }
            } else {
                if (!sign) {
                    z = x - 2 * pio2_1;
                    y[0] = z - 2 * pio2_1t;
                    y[1] = (z - y[0]) - 2 * pio2_1t;
                    return 2;
                } else {
                    z = x + 2 * pio2_1;
                    y[0] = z + 2 * pio2_1t;
                    y[1] = (z - y[0]) + 2 * pio2_1t;
                    return -2;
                }
            }
        }
        if (ix <= 0x401c463b) { // |x| ~<= 9pi/4
            if (ix <= 0x4015fdbc) { // |x| ~<= 7pi/4
                if (ix == 0x4012d97c) { // |x| ~= 3pi/2
                    return medium(ix, x, y);
                }
                if (!sign) {
                    z = x - 3 * pio2_1;
                    y[0] = z - 3 * pio2_1t;
                    y[1] = (z - y[0]) - 3 * pio2_1t;
                    return 3;
                } else {
                    z = x + 3 * pio2_1;
                    y[0] = z + 3 * pio2_1t;
                    y[1] = (z - y[0]) + 3 * pio2_1t;
                    return -3;
                }
            } else {
                if (ix == 0x401921fb) { // |x| ~= 4pi/2 */
                    return medium(ix, x, y);
                }
                if (!sign) {
                    z = x - 4 * pio2_1;
                    y[0] = z - 4 * pio2_1t;
                    y[1] = (z - y[0]) - 4 * pio2_1t;
                    return 4;
                } else {
                    z = x + 4 * pio2_1;
                    y[0] = z + 4 * pio2_1t;
                    y[1] = (z - y[0]) + 4 * pio2_1t;
                    return -4;
                }
            }
        }
        if (ix < 0x413921fb) { // |x| ~< 2^20*(pi/2), medium size
            return medium(ix, x, y);
        }
        // all other (large) arguments
        if (ix >= 0x7ff00000) { // x is inf or NaN
            y[0] = x - x;
            y[1] = y[0];
            return 0;
        }
        // set z = scalbn(|x|,-ilogb(x)+23)
        ui = @bitCast(x);
        ui &= std.math.maxInt(u64) >> 12;
        ui |= @as(u64, 0x3ff + 23) << 52;
        z = @bitCast(ui);

        i = 0;
        while (i < 2) : (i += 1) {
            tx[@intCast(i)] = @floatFromInt(@as(i32, @intFromFloat(z)));
            z = (z - tx[@intCast(i)]) * 0x1p24;
        }
        tx[@intCast(i)] = z;
        // skip zero terms, first term is non-zero
        while (tx[@intCast(i)] == 0.0) {
            i -= 1;
        }
        n = namespaces.rem_pio2_large_kernel.rem_pio2_large(tx[0..], ty[0..], @as(i32, @intCast((ix >> 20))) - (0x3ff + 23), i + 1, 1);
        if (sign) {
            y[0] = -ty[0];
            y[1] = -ty[1];
            return -n;
        }
        y[0] = ty[0];
        y[1] = ty[1];
        return n;
    }
};

/// From `lib/compiler_rt/sin.zig`.
pub const sin_kernel = struct {
    pub fn sin_f64(x: f64) f64 {
        var ix = @as(u64, @bitCast(x)) >> 32;
        ix &= 0x7fffffff;

        // |x| ~< pi/4
        if (ix <= 0x3fe921fb) {
            if (ix < 0x3e500000) { // |x| < 2**-26
                // raise inexact if x != 0 and underflow if subnormal
                if (compiler_rt.want_float_exceptions) {
                    if (ix < 0x00100000) {
                        mem.doNotOptimizeAway(x / 0x1p120);
                    } else {
                        mem.doNotOptimizeAway(x + 0x1p120);
                    }
                }
                return x;
            }
            return namespaces.trig_kernel.sin(x, 0.0, 0);
        }

        // sin(Inf or NaN) is NaN
        if (ix >= 0x7ff00000) {
            return x - x;
        }

        var y: [2]f64 = undefined;
        const n = namespaces.rem_pio2_kernel.rem_pio2(x, &y);
        return switch (n & 3) {
            0 => namespaces.trig_kernel.sin(y[0], y[1], 1),
            1 => namespaces.trig_kernel.cos(y[0], y[1]),
            2 => -namespaces.trig_kernel.sin(y[0], y[1], 1),
            else => -namespaces.trig_kernel.cos(y[0], y[1]),
        };
    }
};

/// From `lib/compiler_rt/cos.zig`.
pub const cos_kernel = struct {
    pub fn cos_f64(x: f64) f64 {
        var ix = @as(u64, @bitCast(x)) >> 32;
        ix &= 0x7fffffff;

        // |x| ~< pi/4
        if (ix <= 0x3fe921fb) {
            if (ix < 0x3e46a09e) { // |x| < 2**-27 * sqrt(2)
                // raise inexact if x!=0
                if (compiler_rt.want_float_exceptions) mem.doNotOptimizeAway(x + 0x1p120);
                return 1.0;
            }
            return namespaces.trig_kernel.cos(x, 0);
        }

        // cos(Inf or NaN) is NaN
        if (ix >= 0x7ff00000) {
            return x - x;
        }

        var y: [2]f64 = undefined;
        const n = namespaces.rem_pio2_kernel.rem_pio2(x, &y);
        return switch (n & 3) {
            0 => namespaces.trig_kernel.cos(y[0], y[1]),
            1 => -namespaces.trig_kernel.sin(y[0], y[1], 1),
            2 => -namespaces.trig_kernel.cos(y[0], y[1]),
            else => namespaces.trig_kernel.sin(y[0], y[1], 1),
        };
    }
};

/// From `lib/compiler_rt/tan.zig`.
pub const tan_kernel = struct {
    pub fn tan_f64(x: f64) f64 {
        var ix = @as(u64, @bitCast(x)) >> 32;
        ix &= 0x7fffffff;

        // |x| ~< pi/4
        if (ix <= 0x3fe921fb) {
            if (ix < 0x3e400000) { // |x| < 2**-27
                // raise inexact if x!=0 and underflow if subnormal
                if (compiler_rt.want_float_exceptions) {
                    if (ix < 0x00100000) {
                        mem.doNotOptimizeAway(x / 0x1p120);
                    } else {
                        mem.doNotOptimizeAway(x + 0x1p120);
                    }
                }
                return x;
            }
            return namespaces.trig_kernel.tan(x, 0.0, false);
        }

        // tan(Inf or NaN) is NaN
        if (ix >= 0x7ff00000) {
            return x - x;
        }

        var y: [2]f64 = undefined;
        const n = namespaces.rem_pio2_kernel.rem_pio2(x, &y);
        return namespaces.trig_kernel.tan(y[0], y[1], n & 1 != 0);
    }
};

/// From `lib/std/math/expo2.zig`.
pub const expo2_kernel = struct {
    pub fn expo2d(x: f64) f64 {
        const k: u32 = 2043;
        const kln2 = 0x1.62066151ADD8BP+10;

        const u = (0x3FF + k / 2) << 20;
        const scale = @as(f64, @bitCast(@as(u64, u) << 32));
        return namespaces.exp_kernel.exp_f64(x - kln2) * scale * scale;
    }
};

/// From `lib/std/math/sinh.zig`.
pub const sinh_kernel = struct {
    pub fn sinh64(x: f64) f64 {
        const u = @as(u64, @bitCast(x));
        const w = @as(u32, @intCast(u >> 32)) & (maxInt(u32) >> 1);
        const ax = @as(f64, @bitCast(u & (maxInt(u64) >> 1)));

        if (x == 0.0 or math.isNan(x)) {
            return x;
        }

        var h: f32 = 0.5;
        if (u >> 63 != 0) {
            h = -h;
        }

        // |x| < log(FLT_MAX)
        if (w < 0x40862E42) {
            const t = math.expm1(ax);
            if (w < 0x3FF00000) {
                if (w < 0x3FF00000 - (26 << 20)) {
                    return x;
                } else {
                    return h * (2 * t - t * t / (t + 1));
                }
            }
            // NOTE: |x| > log(0x1p26) + eps could be h * exp(x)
            return h * (t + t / (t + 1));
        }

        // |x| > log(DBL_MAX) or nan
        return 2 * h * namespaces.expo2_kernel.expo2d(ax);
    }
};

/// From `lib/std/math/cosh.zig`.
pub const cosh_kernel = struct {
    pub fn cosh64(x: f64) f64 {
        const u = @as(u64, @bitCast(x));
        const w = @as(u32, @intCast(u >> 32)) & (maxInt(u32) >> 1);
        const ax = @as(f64, @bitCast(u & (maxInt(u64) >> 1)));

        // TODO: Shouldn't need this explicit check.
        if (x == 0.0) {
            return 1.0;
        }

        // |x| < log(2)
        if (w < 0x3FE62E42) {
            if (w < 0x3FF00000 - (26 << 20)) {
                if (x != 0) {
                    math.raiseInexact();
                }
                return 1.0;
            }
            const t = math.expm1(ax);
            return 1 + t * t / (2 * (1 + t));
        }

        // |x| < log(DBL_MAX)
        if (w < 0x40862E42) {
            const t = namespaces.exp_kernel.exp_f64(ax);
            // NOTE: If x > log(0x1p26) then 1/t is not required.
            return 0.5 * (t + 1 / t);
        }

        // |x| > log(CBL_MAX) or nan
        return namespaces.expo2_kernel.expo2d(ax);
    }
};

/// From `lib/std/math/asinh.zig`.
pub const asinh_kernel = struct {
    pub fn asinh64(x: f64) f64 {
        const u = @as(u64, @bitCast(x));
        const e = (u >> 52) & 0x7FF;
        const s = u >> 63;

        var rx = @as(f64, @bitCast(u & (maxInt(u64) >> 1))); // |x|

        // |x| >= 0x1p26 or inf or nan
        if (e >= 0x3FF + 26) {
            rx = namespaces.log_kernel.log_f64(rx) + 0.693147180559945309417232121458176568;
        }
        // |x| >= 2
        else if (e >= 0x3FF + 1) {
            rx = namespaces.log_kernel.log_f64(2 * rx + 1 / (@sqrt(rx * rx + 1) + rx));
        }
        // |x| >= 0x1p-12, up to 1.6ulp error
        else if (e >= 0x3FF - 26) {
            rx = math.log1p(rx + rx * rx / (@sqrt(rx * rx + 1) + 1));
        }
        // |x| < 0x1p-12, inexact if x != 0
        else {
            mem.doNotOptimizeAway(rx + 0x1.0p120);
        }

        return if (s != 0) -rx else rx;
    }
};

/// From `lib/std/math/acosh.zig`.
pub const acosh_kernel = struct {
    pub fn acosh64(x: f64) f64 {
        const u = @as(u64, @bitCast(x));
        const e = (u >> 52) & 0x7FF;

        // |x| < 2, invalid if x < 1 or nan
        if (e < 0x3FF + 1) {
            return math.log1p(x - 1 + @sqrt((x - 1) * (x - 1) + 2 * (x - 1)));
        }
        // |x| < 0x1p26
        else if (e < 0x3FF + 26) {
            return namespaces.log_kernel.log_f64(2 * x - 1 / (x + @sqrt(x * x - 1)));
        }
        // |x| >= 0x1p26 or nan
        else {
            return namespaces.log_kernel.log_f64(x) + 0.693147180559945309417232121458176568;
        }
    }
};

/// From `lib/std/math/pow.zig`.
pub const pow_kernel = struct {
    pub fn pow(comptime T: type, x: T, y: T) T {
        if (@typeInfo(T) == .int) {
            return math.powi(T, x, y) catch unreachable;
        }

        if (T != f32 and T != f64) {
            @compileError("pow not implemented for " ++ @typeName(T));
        }

        // pow(x, +-0) = 1      for any x
        // pow(1, y) = 1        for any y
        if (y == 0 or x == 1) {
            return 1;
        }

        // pow(nan, y) = nan    for any y != 0
        // pow(x, nan) = nan    for any x != 1
        if (math.isNan(x) or math.isNan(y)) {
            @branchHint(.unlikely);
            return math.nan(T);
        }

        // pow(x, 1) = x        for any x
        if (y == 1) {
            return x;
        }

        if (x == 0) {
            if (y < 0) {
                // pow(+-0, y) = +-inf  for y an odd integer
                if (isOddInteger(y)) {
                    return math.copysign(math.inf(T), x);
                }
                // pow(+-0, y) = +inf   for y an even integer
                else {
                    return math.inf(T);
                }
            } else {
                if (isOddInteger(y)) {
                    return x;
                } else {
                    return 0;
                }
            }
        }

        if (math.isInf(y)) {
            // pow(-1, inf) = 1
            if (x == -1) {
                return 1.0;
            }
            // pow(x, +inf) = +0    for |x| < 1
            // pow(x, -inf) = +0    for |x| > 1
            else if ((@abs(x) < 1) == math.isPositiveInf(y)) {
                return 0;
            }
            // pow(x, -inf) = +inf  for |x| < 1
            // pow(x, +inf) = +inf  for |x| > 1
            else {
                return math.inf(T);
            }
        }

        if (math.isInf(x)) {
            if (math.isNegativeInf(x)) {
                return pow(T, 1 / x, -y);
            }
            // pow(+inf, y) = +0    for y < 0
            else if (y < 0) {
                return 0;
            }
            // pow(+inf, y) = +0    for y > 0
            else if (y > 0) {
                return math.inf(T);
            }
        }

        // special case sqrt
        if (y == 0.5) {
            return @sqrt(x);
        }

        if (y == -0.5) {
            return 1 / @sqrt(x);
        }

        const r1 = math.modf(@abs(y));
        var yi = r1.ipart;
        var yf = r1.fpart;

        if (yf != 0 and x < 0) {
            return math.nan(T);
        }
        if (yi >= 1 << (@typeInfo(T).float.bits - 1)) {
            // yi is a large even int, so the result is always positive
            // and the sign of x doesn't matter
            return namespaces.exp_kernel.exp_f64(y * namespaces.log_kernel.log_f64(@abs(x)));
        }

        // a = a1 * 2^ae
        var a1: T = 1.0;
        var ae: i32 = 0;

        // a *= x^yf
        if (yf != 0) {
            if (yf > 0.5) {
                yf -= 1;
                yi += 1;
            }
            a1 = namespaces.exp_kernel.exp_f64(yf * namespaces.log_kernel.log_f64(x));
        }

        // a *= x^yi
        const r2 = math.frexp(x);
        var xe = r2.exponent;
        var x1 = r2.significand;

        var i = @as(@Int(.signed, @typeInfo(T).float.bits), @intFromFloat(yi));
        while (i != 0) : (i >>= 1) {
            const overflow_shift = math.floatExponentBits(T) + 1;
            if (xe < -(1 << overflow_shift) or (1 << overflow_shift) < xe) {
                // catch xe before it overflows the left shift below
                // Since i != 0 it has at least one bit still set, so ae will accumulate xe
                // on at least one more iteration, ae += xe is a lower bound on ae
                // the lower bound on ae exceeds the size of a float exp
                // so the final call to Ldexp will produce under/overflow (0/Inf)
                ae += xe;
                break;
            }
            if (i & 1 == 1) {
                a1 *= x1;
                ae += xe;
            }
            x1 *= x1;
            xe <<= 1;
            if (x1 < 0.5) {
                x1 += x1;
                xe -= 1;
            }
        }

        // a *= a1 * 2^ae
        if (y < 0) {
            a1 = 1 / a1;
            ae = -ae;
        }

        return math.scalbn(a1, ae);
    }

    pub fn isOddInteger(x: f64) bool {
        if (@abs(x) >= 1 << 53) {
            // From https://golang.org/src/math/pow.go
            // 1 << 53 is the largest exact integer in the float64 format.
            // Any number outside this range will be truncated before the decimal point and therefore will always be
            // an even integer.
            // Without this check and if x overflows i64 the @intFromFloat(r.ipart) conversion below will panic
            return false;
        }
        const r = math.modf(x);
        return r.fpart == 0.0 and @as(i64, @intFromFloat(r.ipart)) & 1 == 1;
    }
};
