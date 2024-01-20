// Some parts taken from https://github.com/GreenLightning/gpu-font-rendering/

override show_control_points: bool = false;
override show_segments: bool = false;
override show_em_uv: bool = false;

@group(0) @binding(0)
var<storage, read> glyph_data: array<u32>;

struct GlyphInstance {
    @location(0) top_left: vec2<f32>,
    @location(1) scale: vec2<f32>,
    @location(2) glyph_data_begin: u32,
};

struct VertexOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) em_uv: vec2<f32>,
    @location(1) @interpolate(flat) em_window_bottom_left: vec2<f32>,
    @location(2) @interpolate(flat) em_window_size: vec2<f32>,
    @location(3) @interpolate(flat) vert_bands_length: u32,
    @location(4) @interpolate(flat) hori_bands_length: u32,
    @location(5) @interpolate(flat) vert_band_ends_ofs: u32,
    @location(6) @interpolate(flat) hori_band_ends_ofs: u32,
    @location(7) @interpolate(flat) vert_band_curves_ofs: u32,
    @location(8) @interpolate(flat) hori_band_curves_ofs: u32,
    @location(9) @interpolate(flat) glyph_points_ofs: u32,
}

fn glyph_get_u16(ofs: u32, u16_idx: u32) -> u32 {
    // 0xAB12, 0xCD34 -> (u16's written as LE u8)  0x12, 0xAB, 0x34, 0xCD
    //                -> (u8's  read    as LE u32) 0xCD34AB12
    // so to read the first we need to shift by 0 and by 16 for the second.
    return (
        glyph_data[ofs + u16_idx / 2u] >> (16u * (u16_idx % 2u))
    ) & 0xFFFF;
}

fn glyph_get_vec2f(ofs: u32, vec2f_idx: u32) -> vec2<f32> {
    let base = ofs + vec2f_idx * 2u;
    return vec2<f32>(
        bitcast<f32>(glyph_data[base]),
        bitcast<f32>(glyph_data[base + 1u]),
    );
}

fn u32_padded_u16_size(u16_size: u32) -> u32 {
    return (u16_size / 2u) + (u16_size % 2u);
}

@vertex fn vertex_main(
    instance: GlyphInstance,
    @builtin(vertex_index) v_index: u32,
) -> VertexOut {
    var out: VertexOut;

    let glyph_data_ofs = instance.glyph_data_begin;
    let glyph_info_ofs = glyph_data_ofs + 0u;
    let em_window_bottom_left = glyph_get_vec2f(glyph_info_ofs, 0);
    let em_window_top_right = glyph_get_vec2f(glyph_info_ofs, 1);
    let em_window_size = em_window_top_right - em_window_bottom_left;

    out.em_window_bottom_left = em_window_bottom_left;
    out.em_window_size = em_window_size;

    let glyph_lengths_ofs = glyph_data_ofs + 4u;
    let vert_bands_length = glyph_get_u16(glyph_lengths_ofs, 0u);
    let hori_bands_length = glyph_get_u16(glyph_lengths_ofs, 1u);

    let vert_band_ends_ofs = glyph_data_ofs + 5u;
    let vert_band_curves_ofs = vert_band_ends_ofs +
        u32_padded_u16_size(vert_bands_length);
    let vert_band_curves_length = 
        glyph_get_u16(vert_band_ends_ofs, vert_bands_length - 1u) + 1u;

    let hori_band_ends_ofs = vert_band_curves_ofs +
        u32_padded_u16_size(vert_band_curves_length);
    let hori_band_curves_ofs = hori_band_ends_ofs +
        u32_padded_u16_size(hori_bands_length);
    let hori_band_curves_length = 
        glyph_get_u16(hori_band_ends_ofs, hori_bands_length - 1u) + 1u;

    let glyph_points_ofs = hori_band_curves_ofs +
        u32_padded_u16_size(hori_band_curves_length);

    out.vert_bands_length = vert_bands_length;
    out.hori_bands_length = hori_bands_length;
    out.vert_band_curves_ofs = vert_band_curves_ofs;
    out.vert_band_ends_ofs = vert_band_ends_ofs;
    out.hori_band_curves_ofs = hori_band_curves_ofs;
    out.hori_band_ends_ofs = hori_band_ends_ofs;
    out.glyph_points_ofs = glyph_points_ofs;

    let indicator = array(
        vec2<u32>(0, 0),
        vec2<u32>(0, 1),
        vec2<u32>(1, 0),
        vec2<u32>(1, 0),
        vec2<u32>(0, 1),
        vec2<u32>(1, 1),
    )[v_index];

    out.em_uv = vec2f(
        array(em_window_bottom_left.x, em_window_top_right.x)[indicator.x],
        array(em_window_top_right.y, em_window_bottom_left.y)[indicator.y],
    );

    let em_window_top_left_ofs = vec2f(
        em_window_bottom_left.x,
        1.0 - em_window_top_right.y,
    ) * instance.scale;
    let top_left = instance.top_left + em_window_top_left_ofs;
    let size = em_window_size * instance.scale;
    let pos = top_left + vec2<f32>(indicator) * size;
    out.pos = vec4<f32>(pos, 0.0, 1.0);

    return out;
}

fn rand(p: f32) -> f32 {
    return rand2d(vec2f(p));
}

fn rand2d(p: vec2f) -> f32 {
    let K1 = vec2f(
        23.14069263277926, // e^pi (Gelfond's constant)
         2.665144142690225 // 2^sqrt(2) (Gelfondâ€“Schneider constant)
    );
    return fract(cos(dot(p, K1)) * 12345.6789);
}

fn rand_color(p: f32) -> vec3f {
    let rand_1 = rand(p);
    let rand_2 = rand(p + 1.4398);
    let rand_3 = rand(p + 2.123);
    return vec3f(rand_1, rand_2, rand_3);
}

fn rand_color_2d(p: vec2f) -> vec3f {
    let rand_1 = rand2d(p);
    let rand_2 = rand2d(p + vec2f(1.4398, 9.312));
    let rand_3 = rand2d(p + vec2f(2.123, 3.348));
    return vec3f(rand_1, rand_2, rand_3);
}

fn compute_coverage_for_curve(
    inverse_sample_diameter: f32,
    p0: vec2<f32>,
    p1: vec2<f32>,
    p2: vec2<f32>,
) -> f32 {
    // t0m(A,B,C) = A!(BC) + (!A)B(!C) = A(!B) + B(!C)
    // t1m(A,B,C) = T0(!A,!B,!C) = (!A)B + (!B)C

    let yp: vec3<bool> = vec3<f32>(p0.y, p1.y, p2.y) > vec3<f32>(0.0);
    let t0m = (yp.x && !yp.y) || (yp.y && !yp.z);
    let t1m = (!yp.x && yp.y) || (!yp.y && yp.z);
    if (!t0m && !t1m) { return 0; }

    // NOTE: Simplified from abc formula by extracting a factor of (-2) from b.
    let a = p0 - 2*p1 + p2;
    let b = p0 - p1;
    let c = p0;

    var t0 = 0.0;
    var t1 = 0.0;

    if (abs(a.y) >= 1e-5) {
        // Quadratic segment, solve abc formula to find roots.
        let radicand = b.y*b.y - a.y*c.y;
        if (radicand <= 0) { return 0; }

        let s = sqrt(radicand);
        let ainv = 1.0 / a.y;
        t0 = (b.y - s) * ainv;
        t1 = (b.y + s) * ainv;
    } else {
        t0 = p0.y / (p0.y - p2.y);
        t1 = t0;
    }

    var alpha: f32 = 0.0;
    if (t0m) {
        let x0 = (a.x*t0 - 2.0*b.x)*t0 + c.x;
        alpha += saturate(x0 * inverse_sample_diameter + 0.5);
    }
    if (t1m) {
        let x1 = (a.x*t1 - 2.0*b.x)*t1 + c.x;
        alpha -= saturate(x1 * inverse_sample_diameter + 0.5);
    }
    return alpha;
}

fn compute_coverage(
    is_vertical_curve_band: bool,
    glyph_points_ofs: u32,
    band_curves_ofs: u32,
    curves_begin: u32,
    curves_end: u32,
    inv_sample_diam: f32,
    em_uv: vec2<f32>,
) -> f32 {
    var alpha: f32 = 0.0;

    for (var i = curves_begin; i <= curves_end; i++) {
        let first_point_idx = glyph_get_u16(band_curves_ofs, i);

        // == Compute sample coverage by the curve == //

        var p0 = glyph_get_vec2f(glyph_points_ofs, first_point_idx)
            - em_uv;
        var p1 = glyph_get_vec2f(glyph_points_ofs, first_point_idx + 1u)
            - em_uv;
        var p2 = glyph_get_vec2f(glyph_points_ofs, first_point_idx + 2u) 
            - em_uv;

        if (is_vertical_curve_band) {
            // rotate
            p0 = vec2f(p0.y, -p0.x);
            p1 = vec2f(p1.y, -p1.x);
            p2 = vec2f(p2.y, -p2.x);
        }

        alpha += compute_coverage_for_curve(inv_sample_diam, p0, p1, p2);

    }

    return alpha;
}


const PKIND_NONE: u32 = 0;
const PKIND_P0: u32 = 1;
const PKIND_P1: u32 = 1 << 1;
const PKIND_P2: u32 = 1 << 2;
struct PKindRes {
    pkind: u32,
    dist: f32,
}

fn get_control_point_kind(
    glyph_points_ofs: u32,
    vert_band_curves_ofs: u32,
    hori_band_curves_ofs: u32,
    vert_curves_begin: u32,
    vert_curves_end: u32, 
    hori_curves_begin: u32, 
    hori_curves_end: u32,
    em_uv: vec2<f32>,
    radius: f32,
) -> PKindRes {
    const VERY_LARGE_F32: f32 = 1e30;

    var pkind = PKIND_NONE;
    var dist = VERY_LARGE_F32;
    let band_curves_ofs = array(vert_band_curves_ofs, hori_band_curves_ofs);
    let curves_begin = array(vert_curves_begin, hori_curves_begin);
    let curves_end = array(vert_curves_end, hori_curves_end);
    let r2 = radius * radius;

    for (var j = 0u; j < 2; j++) {
        for (var i = curves_begin[j]; i <= curves_end[j]; i++) {
            let first_point_idx = glyph_get_u16(band_curves_ofs[j], i);

            var p0 = glyph_get_vec2f(glyph_points_ofs, first_point_idx)
                - em_uv;
            var p1 = glyph_get_vec2f(glyph_points_ofs, first_point_idx + 1u)
                - em_uv;
            var p2 = glyph_get_vec2f(glyph_points_ofs, first_point_idx + 2u) 
                - em_uv;

            if (dot(p0, p0) < r2) {
                pkind |= PKIND_P0;
                dist = min(dist, length(p0));
            }
            if (dot(p1, p1) < r2) {
                pkind |= PKIND_P1;
                dist = min(dist, length(p1));
            }
            // if (dot(p2, p2) < r2) {
            //     pkind |= PKIND_P2;
            //     dist = min(dist, length(p2));
            // }
        }
    }

    return PKindRes(pkind, dist);
}

fn control_points_overlay(
    glyph_points_ofs: u32,
    vert_band_curves_ofs: u32,
    hori_band_curves_ofs: u32,
    vert_curves_begin: u32,
    vert_curves_end: u32, 
    hori_curves_begin: u32, 
    hori_curves_end: u32,
    fw: vec2<f32>,
    em_uv: vec2<f32>,
) -> vec4<f32> {
    let em_per_unit = min(fw.x, fw.y);
    let radius = 2.5;
    let aa_radius = 0.5;

    let pkind_res = get_control_point_kind(
        glyph_points_ofs,
        vert_band_curves_ofs,
        hori_band_curves_ofs,
        vert_curves_begin,
        vert_curves_end, 
        hori_curves_begin, 
        hori_curves_end,
        em_uv,
        (radius + aa_radius) * em_per_unit,
    );
    let dist = pkind_res.dist / em_per_unit;

    let ol_alpha = 
        saturate((radius - dist + aa_radius) / aa_radius);

    switch pkind_res.pkind {
        case PKIND_NONE: {}

        case PKIND_P0, PKIND_P2: {
            return vec4<f32>(1.0, 1.0, 0.0, ol_alpha);
        }
        case PKIND_P1: {
            return vec4<f32>(0.0, 1.0, 0.0, ol_alpha);
        }
        default: {
            return vec4<f32>(1.0, 0.0, 1.0, ol_alpha);
        }
    }
    return vec4<f32>(0.0);
}


fn blend(bg: vec4<f32>, fg: vec4<f32>) -> vec4<f32> {
    return vec4<f32>(
        bg.xyz * (1.0 - fg.w) + fg.xyz * fg.w,
        bg.w * (1.0 - fg.w) + fg.w,
    );
}

@fragment fn frag_main(vert: VertexOut) -> @location(0) vec4<f32> {
    let em_uv = vert.em_uv;

    let fw = fwidth(em_uv);
    let inverse_sample_diameter = 1.0 / (1.4*fw);

    let em_window_bottom_left = vert.em_window_bottom_left;
    let em_window_size = vert.em_window_size;

    let band_count = vec2<u32>(
        vert.vert_bands_length, 
        vert.hori_bands_length, 
    );
    let band_size = em_window_size / vec2<f32>(band_count);
    let band_idx = vec2<u32>(trunc(
        (em_uv - em_window_bottom_left) / band_size)
    );

    var vert_curves_begin: u32 = 0u;
    var hori_curves_begin: u32 = 0u;
    if (band_idx.x > 0u) {
        vert_curves_begin =
            glyph_get_u16(vert.vert_band_ends_ofs, band_idx.x - 1u) + 1u;
    }
    if (band_idx.y > 0u) {
        hori_curves_begin =
            glyph_get_u16(vert.hori_band_ends_ofs, band_idx.y - 1u) + 1u;
    }
    let vert_curves_end = glyph_get_u16(vert.vert_band_ends_ofs, band_idx.x);
    let hori_curves_end = glyph_get_u16(vert.hori_band_ends_ofs, band_idx.y);

    var alpha: f32 = 0.0;

    alpha += compute_coverage( 
        false,
        vert.glyph_points_ofs,
        vert.hori_band_curves_ofs,
        hori_curves_begin,
        hori_curves_end,
        inverse_sample_diameter.x,
        em_uv,
    );
    alpha += compute_coverage( 
        true,
        vert.glyph_points_ofs,
        vert.vert_band_curves_ofs,
        vert_curves_begin,
        vert_curves_end,
        inverse_sample_diameter.y,
        em_uv,
    );

    alpha = saturate(alpha * 0.5);

    var out = vec4<f32>(0.0, 0.0, 0.0, alpha);

    if (show_em_uv) {
        out.x = em_uv.x;
        out.y = em_uv.y;
    }

    if (show_control_points) {
        let overlay = control_points_overlay(
            vert.glyph_points_ofs,
            vert.vert_band_curves_ofs,
            vert.hori_band_curves_ofs,
            vert_curves_begin,
            vert_curves_end, 
            hori_curves_begin, 
            hori_curves_end,
            fw,
            em_uv,
        );
        out = blend(out, overlay);
    }

    if (show_segments) {
        let seg = vec4<f32>(rand_color_2d(vec2<f32>(
            f32(hori_curves_begin),
            f32(vert_curves_begin),
        )), 0.5);
        // let seg = vec4<f32>(
        //     vec2<f32>(band_idx) / vec2<f32>(band_count),
        //     0.0,
        //     0.5,
        // );
        out = blend(seg, out);
    }

    return out;

    // let xy_even = floor(vert.uv * 6.0) % 2.0;
    // return vec4<f32>(1.0, 0.0, 1.0, abs(xy_even.x - xy_even.y));
}
